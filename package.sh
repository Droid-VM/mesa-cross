#!/bin/bash
# Turn a staged `meson install` tree into a distro package.
#
#   package.sh <variant> <version> <stagedir> <outdir>
#
# Called by build-in-container.sh once the build is done, so the staged tree and the environment
# files it ships are described in exactly one place.
#
# What has to be true on both, and why:
#
#   * The two variants share ~60 install paths (every kmsro *_dri.so, the gbm backend, libgallium)
#     and are therefore mutually exclusive. Conflicts+Replaces naming the OTHER variant is what
#     makes dpkg REMOVE it rather than refuse (Conflicts alone) or silently overwrite it: both
#     ship libgallium, the desktop composites through gallium rather than through the Vulkan ICD,
#     and an overwrite is invisible until the whole screen is black.
#
#   * The environment is part of the package. MESA_LOADER_DRIVER_OVERRIDE=zink is not a tuning
#     knob -- both variants are built -Dgallium-drivers=zink, so without it GNOME Shell gets
#     "virtio_gpu: driver missing", falls back to kms_swrast and fails with "No GPUs found", while
#     Vulkan works the whole time and it looks like a gdm fault.
set -euo pipefail

# exec'd from build-in-container.sh, so the variant helpers have to be sourced again here.
source "${WORK_OUT:-/work/out}/mesa-variants.sh"

V=${1:?variant}
PKGVER=${2:?version}
STAGE=${3:?stagedir}
OUT=${4:?outdir}

pkg=$(mesa_variant_pkg "$V")
siblings=$(mesa_variant_siblings "$V")
icd=$(mesa_variant_icd "$V")

# ---------------------------------------------------------------------------
# Environment, delivered through FOUR channels because no single one reaches every entry point.
#
#   /usr/lib/environment.d          systemd USER sessions -- GNOME, and the gdm greeter, which is one
#   /etc/profile.d                  login shells
#   /etc/environment                PAM sessions, via pam_env -- notably display-manager greeters
#                                   that are NOT systemd user sessions
#   /usr/lib/systemd/system.conf.d  systemd SYSTEM services -- notably the X server, which a display
#                                   manager spawns itself rather than through PAM
#
# The third was added after a black screen on KDE/sddm. sddm spawns its greeter from sddm-helper
# through PAM, not through `systemd --user`, so environment.d never reached it. Measured on the
# guest, greeter environment / crash count:
#
#   environment.d only            no MESA_LOADER_DRIVER_OVERRIDE, crash loop
#   + sddm.service.d Environment= still none (sddm-helper rebuilds the env), crash loop
#   + /etc/environment            present, crashes 3 -> 0, login screen renders
#
# The fourth closes what that left open. Giving the GREETER the override fixes the client half; the
# X SERVER is a different process, spawned by the sddm daemon directly, and it never saw any of the
# three. So glamor kept failing and GLX kept falling back to software, which offers the greeter no
# FBConfig it will accept -- "qglx_findConfig: Failed to finding matching FBConfig", "Could not
# initialize GLX", exit 6, and sddm restarts the display forever. Logging in still worked, because
# autologin goes straight to a Wayland session and never starts an X server; only logging back out
# reached it. Same X server, same command line, only the environment differing:
#
#   without   couldn't get display device / glamor initialization failed
#             AIGLX: Screen 0 is not DRI2 capable / GLX: Initialized DRISWRAST GL provider
#   with      glamor initialized
#             AIGLX: Loaded and initialized zink / GLX: Initialized DRI2 GL provider
#
# system.conf.d rather than a drop-in per display manager: the note above records that sddm's own
# service environment does not reach its greeter, so a per-DM drop-in would have to be written for
# each DM and would still only be half the answer. DefaultEnvironment is the system-service
# counterpart of /etc/environment, and it does not care which DM is installed.
#
# MESA_LOADER_DRIVER_OVERRIDE is not a tuning knob. Both variants are built
# -Dgallium-drivers=zink, so nothing in dri/ is named for the guest's kernel driver, and
# pipe_loader asks for one named "virtio_gpu". Without the override it finds nothing:
# "QGLXContext: Failed to create dummy context", and whatever needed GL dies.
#
# VK_DRIVER_FILES is not strictly required -- the loader already searches /usr/local/share/vulkan
# -- but pinning it keeps the distro's software ICDs (lavapipe) out of the enumeration. An app
# quietly choosing llvmpipe is slow rather than broken, which is the hardest kind of regression to
# notice.
#
# /etc/environment IS the admin's file, and that is why it is edited from the maintainer scripts
# inside named markers rather than shipped: postinst strips every mesa-guest block before adding
# its own, postrm strips its own on removal, so nothing this package did not write is ever touched
# and nothing it wrote is ever left behind. pam_env has no drop-in directory -- it reads only
# /etc/environment and /etc/security/pam_env.conf, both conffiles of other packages -- so there is
# no way to reach a PAM session without touching one of them.
# ---------------------------------------------------------------------------
#
# NO KWIN_FORCE_SW_CURSOR here, deliberately. It was shipped for a while because the guest's
# hardware cursor plane never reached the screen and forcing KWin to draw the pointer into the
# framebuffer was the only way to see one. The host now presents the cursor plane properly (crosvm
# composites it for VNC, and the app hosts an overlay Surface for the native path), so the
# workaround would do active harm: it stops KWin ever using the cursor plane, which makes the
# hardware path look broken and hides any regression in it. It also only ever helped Linux
# compositors -- Windows' virtio-gpu driver and UEFI have no equivalent knob.
install -d -m 0755 "$STAGE/usr/lib/environment.d" "$STAGE/etc/profile.d" \
                   "$STAGE/usr/lib/systemd/system.conf.d"
cat > "$STAGE/usr/lib/environment.d/50-mesa-guest.conf" <<EOF
# Installed by ${pkg}. See /usr/share/doc/${pkg}.
MESA_LOADER_DRIVER_OVERRIDE=zink
VK_DRIVER_FILES=${icd}
VK_ICD_FILENAMES=${icd}
EOF
cat > "$STAGE/etc/profile.d/50-mesa-guest.sh" <<EOF
# Installed by ${pkg}.
export MESA_LOADER_DRIVER_OVERRIDE=zink
export VK_DRIVER_FILES=${icd}
export VK_ICD_FILENAMES=${icd}
EOF
# Under /usr/lib, not /etc: systemd reads system.conf.d from both, and the vendor path keeps this a
# plain packaged file instead of something the maintainer scripts have to edit and unpick.
cat > "$STAGE/usr/lib/systemd/system.conf.d/50-mesa-guest.conf" <<EOF
# Installed by ${pkg}. Reaches system services -- above all the X server a display manager starts,
# which needs the override for glamor and therefore for hardware GLX.
[Manager]
DefaultEnvironment=MESA_LOADER_DRIVER_OVERRIDE=zink VK_DRIVER_FILES=${icd} VK_ICD_FILENAMES=${icd}
EOF
chmod 0644 "$STAGE/usr/lib/environment.d/50-mesa-guest.conf" "$STAGE/etc/profile.d/50-mesa-guest.sh" \
           "$STAGE/usr/lib/systemd/system.conf.d/50-mesa-guest.conf"

root=$(mktemp -d)/deb
mkdir -p "$root"; cp -a "$STAGE/." "$root/"
install -d -m 0755 "$root/DEBIAN"
cat > "$root/DEBIAN/control" <<EOF
Package: ${pkg}
Version: ${PKGVER}
Section: libs
Priority: optional
Architecture: arm64
Installed-Size: $(du -sk "$root" | cut -f1)
Maintainer: Droid-VM <noreply@github.com>
Depends: libc6, libdrm2, libexpat1, libgcc-s1, libglvnd0, libstdc++6, libudev1, libvulkan1, libwayland-client0, libwayland-egl1, libwayland-server0, libx11-6, libx11-xcb1, libxcb1, libxcb-dri2-0, libxcb-dri3-0, libxcb-glx0, libxcb-present0, libxcb-randr0, libxcb-shm0, libxcb-sync1, libxcb-xfixes0, libxdamage1, libxext6, libxrandr2, libxshmfence1, libxxf86vm1, libzstd1, zlib1g
Provides: mesa-guest
Conflicts: mesa-guest, ${siblings}
Replaces: mesa-guest, ${siblings}
Description: Guest Mesa for Droid-VM (${V} route)
 Mesa guest libraries with the ${V} Vulkan driver, the Zink Gallium driver and
 the GLVND vendor libraries. Installs to /usr/local, and ships the environment it
 needs in /usr/lib/environment.d, /etc/profile.d, /usr/lib/systemd/system.conf.d
 and a marked block in /etc/environment, so a desktop comes up without any manual
 setup. The last two are the ones that reach a display manager: its greeter runs
 as a PAM session rather than a systemd user session, and the X server it starts
 is a system service that sees neither.
 .
 Only one mesa-guest-* package can be installed at a time: they share a prefix.
EOF
# sed -i on /etc/environment, with the block delimited by markers naming THIS variant.
# postinst strips EVERY mesa-guest block before appending its own: the two variants Conflict, so
# at most one may survive, and this makes the swap converge whichever order dpkg runs the scripts
# in. postrm strips only its own, so it cannot delete a block the other variant has just written.
cat > "$root/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
ldconfig
[ "\$1" = configure ] || exit 0
# pam_env reads /etc/environment, and a display-manager greeter is a PAM session rather than a
# systemd user session -- this is the only channel that reaches one.
if [ -f /etc/environment ]; then
    sed -i '/^# BEGIN mesa-guest-/,/^# END mesa-guest-/d' /etc/environment
else
    : > /etc/environment
fi
cat >> /etc/environment <<'ENVEOF'
# BEGIN mesa-guest-${V} (managed by ${pkg}; edits inside this block are lost on upgrade)
MESA_LOADER_DRIVER_OVERRIDE=zink
VK_DRIVER_FILES=${icd}
VK_ICD_FILENAMES=${icd}
# END mesa-guest-${V}
ENVEOF
# DefaultEnvironment is manager configuration, so PID 1 only picks up the file we just installed on
# re-exec; daemon-reload does not re-read system.conf. Without this the display manager keeps the
# environment it was started with until the next boot, which is exactly the case that was broken.
# Not fatal if it fails -- a reboot has the same effect -- so never fail the install over it.
if [ -d /run/systemd/system ]; then
    systemctl daemon-reexec || echo "${pkg}: systemctl daemon-reexec failed; reboot to apply" >&2
fi
EOF
cat > "$root/DEBIAN/postrm" <<EOF
#!/bin/sh
set -e
ldconfig
case "\$1" in remove|purge) ;; *) exit 0 ;; esac
if [ -f /etc/environment ]; then
    sed -i '/^# BEGIN mesa-guest-${V}/,/^# END mesa-guest-${V}/d' /etc/environment
fi
# dpkg has removed our system.conf.d drop-in, but PID 1 still holds what it said -- including a
# VK_DRIVER_FILES naming an ICD that no longer exists. Drop it the same way postinst applied it.
if [ -d /run/systemd/system ]; then
    systemctl daemon-reexec || true
fi
exit 0
EOF
chmod 0755 "$root/DEBIAN/postinst" "$root/DEBIAN/postrm"

deb="${pkg}_${PKGVER}_arm64.deb"
dpkg-deb --root-owner-group --build "$root" "$OUT/$deb"
echo "wrote $deb (variant $V, ICD $icd)"
