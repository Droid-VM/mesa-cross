#!/bin/bash
# Turn a staged `meson install` tree into a distro package.
#
#   package.sh <version> <stagedir> <outdir>
#
# Called by build-in-container.sh once the build is done, so the staged tree and the environment
# files it ships are described in exactly one place.
#
# What has to be true on both, and why:
#
#   * One package now carries all three routes, so nothing has to be swapped to change route.
#     The per-route packages it replaces installed to the same ~60 paths (every kmsro *_dri.so,
#     the gbm backend, libgallium), so they are named in Conflicts+Replaces: that pair makes dpkg
#     REMOVE them rather than refuse the install (Conflicts alone) or overwrite their files behind
#     dpkg's back. They all shipped libgallium, the desktop composites through gallium rather than
#     through the Vulkan ICD, and a leftover copy is invisible until the whole screen is black.
#
#     NOTHING is said about the virtual name mesa-guest any more, and that is deliberate. The
#     per-route packages carried Provides+Conflicts+Replaces on it, which is the ordinary "only one
#     provider" idiom -- but this package is NAMED mesa-guest, so providing it made the old
#     packages' `Conflicts: mesa-guest` unresolvable for dpkg: on a guest still holding
#     mesa-guest-venus, `dpkg -i` refused with "mesa-guest provides mesa-guest and is to be
#     installed / conflicting packages - not installing mesa-guest". Dropping the Provides line
#     makes the same install remove the old package instead (measured both ways in a scratch dpkg
#     root). apt was never affected -- it plans the removal itself -- but `dpkg -i` is what someone
#     reaches for when apt is not around, and its refusal names the wrong culprit.
#
#   * The environment is part of the package. MESA_LOADER_DRIVER_OVERRIDE=zink is not a tuning
#     knob -- the build is -Dgallium-drivers=zink, so without it GNOME Shell gets
#     "virtio_gpu: driver missing", falls back to kms_swrast and fails with "No GPUs found", while
#     Vulkan works the whole time and it looks like a gdm fault.
set -euo pipefail

# exec'd from build-in-container.sh, so the configuration has to be sourced again here.
source "${WORK_CROSS:-/work/cross}/mesa-config.sh"

PKGVER=${1:?version}
STAGE=${2:?stagedir}
OUT=${3:?outdir}

pkg=$MESA_PKG
siblings=$(mesa_supersedes_list)
# Every ICD, colon-separated. The loader tries each and keeps whichever enumerates a device; a
# DroidVM guest sees exactly one virtio-gpu capset, so exactly one answers.
icd=$(mesa_icd_list)

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
# MESA_LOADER_DRIVER_OVERRIDE is not a tuning knob. The build is
# -Dgallium-drivers=zink, so nothing in dri/ is named for the guest's kernel driver, and
# pipe_loader asks for one named "virtio_gpu". Without the override it finds nothing:
# "QGLXContext: Failed to create dummy context", and whatever needed GL dies.
#
# VK_DRIVER_FILES lists all three of our ICDs. It keeps the distro's software ICDs (lavapipe) out
# of the enumeration -- an app quietly choosing llvmpipe is slow rather than broken, which is the
# hardest kind of regression to notice -- and it is also how the route gets chosen now: the loader
# initialises each in turn and the ones whose capset the VMM did not expose enumerate no device.
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
Conflicts: ${siblings}
Replaces: ${siblings}
Description: Guest Mesa for Droid-VM (gfxstream, venus and drm2kgsl)
 Mesa guest libraries carrying all three DroidVM Vulkan drivers -- gfxstream,
 venus (virtio) and freedreno over vdrm -- plus the Zink Gallium driver and
 the GLVND vendor libraries. The route is chosen at run time: VK_DRIVER_FILES
 names all three ICDs and the loader keeps whichever one enumerates a device,
 which on a DroidVM guest is the one matching the virtio-gpu capset the VMM
 exposed. Installs to /usr/local, and ships the environment it
 needs in /usr/lib/environment.d, /etc/profile.d, /usr/lib/systemd/system.conf.d
 and a marked block in /etc/environment, so a desktop comes up without any manual
 setup. The last two are the ones that reach a display manager: its greeter runs
 as a PAM session rather than a systemd user session, and the X server it starts
 is a system service that sees neither.
 .
 Supersedes the per-route mesa-guest-gfxstream, mesa-guest-venus, mesa-guest-drm2kgsl
 and mesa-guest-kgsl packages, which installed to the same prefix.
EOF
# sed -i on /etc/environment, with the block delimited by markers. postinst strips EVERY
# mesa-guest block before appending its own, so a guest upgrading from one of the old per-route
# packages converges whichever order dpkg runs the scripts in; postrm strips only this package's
# own block.
cat > "$root/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
ldconfig
[ "\$1" = configure ] || exit 0
# pam_env reads /etc/environment, and a display-manager greeter is a PAM session rather than a
# systemd user session -- this is the only channel that reaches one.
# Built beside the target and renamed over it, never appended to in place. An append that is
# interrupted -- the VM losing power, which on this platform means the VMM crashing -- leaves the
# file extended to its new length with the tail unwritten, which on ext4 reads back as NUL bytes.
# pam_env then refuses the whole file, and the one channel that reaches a display manager's PAM
# session goes silent while the other three stay correct. Seen exactly that: a desktop with no
# driver override, on a guest whose environment.d and system.conf.d were both intact.
umask 022
if [ -f /etc/environment ]; then
    sed '/^# BEGIN mesa-guest/,/^# END mesa-guest/d' /etc/environment > /etc/environment.dpkg-new
else
    : > /etc/environment.dpkg-new
fi
cat >> /etc/environment.dpkg-new <<'ENVEOF'
# BEGIN mesa-guest (managed by ${pkg}; edits inside this block are lost on upgrade)
MESA_LOADER_DRIVER_OVERRIDE=zink
VK_DRIVER_FILES=${icd}
VK_ICD_FILENAMES=${icd}
# END mesa-guest
ENVEOF
sync /etc/environment.dpkg-new 2>/dev/null || true
mv -f /etc/environment.dpkg-new /etc/environment
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
    sed '/^# BEGIN mesa-guest/,/^# END mesa-guest/d' /etc/environment \
        > /etc/environment.dpkg-new && mv -f /etc/environment.dpkg-new /etc/environment
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
echo "wrote $deb (ICDs: $icd)"
