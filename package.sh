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
# Environment, delivered through THREE channels because no single one reaches every entry point.
#
#   /usr/lib/environment.d   systemd USER sessions -- GNOME, and the gdm greeter, which runs as one
#   /etc/profile.d           login shells
#   /etc/environment         PAM sessions, via pam_env -- everything else, notably display-manager
#                            greeters that are NOT systemd user sessions
#
# The third one was added after a black screen on KDE/sddm that took a while to place. sddm spawns
# its greeter from sddm-helper through PAM, not through `systemd --user`, so environment.d never
# reached it; the greeter then could not create a GL context at all and sddm restarted it every six
# seconds. Measured on the guest, greeter environment / crash count:
#
#   environment.d only            no MESA_LOADER_DRIVER_OVERRIDE, crash loop
#   + sddm.service.d Environment= still none (sddm-helper rebuilds the env), crash loop
#   + /etc/environment            present, crashes 3 -> 0, login screen renders
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
# KWIN_FORCE_SW_CURSOR is the odd one out: it is not a mesa setting at all. KWin puts the cursor
# on a hardware DRM cursor plane by default, and on virtio-gpu here that plane never reaches the
# screen -- the desktop renders correctly and the pointer is simply invisible, which reads as an
# input problem rather than a display one. Forcing KWin to composite the cursor into the frame
# fixes it, on both routes.
#
# It belongs to the virtio-gpu layer, i.e. droidvm-guest-additions, and it lives here only because
# this is the package that has environment delivery. Move it if that package ever grows the same
# three channels. (Harmless outside KWin: nothing else reads it.)
install -d -m 0755 "$STAGE/usr/lib/environment.d" "$STAGE/etc/profile.d"
cat > "$STAGE/usr/lib/environment.d/50-mesa-guest.conf" <<EOF
# Installed by ${pkg}. See /usr/share/doc/${pkg}.
MESA_LOADER_DRIVER_OVERRIDE=zink
VK_DRIVER_FILES=${icd}
VK_ICD_FILENAMES=${icd}
KWIN_FORCE_SW_CURSOR=1
EOF
cat > "$STAGE/etc/profile.d/50-mesa-guest.sh" <<EOF
# Installed by ${pkg}.
export MESA_LOADER_DRIVER_OVERRIDE=zink
export VK_DRIVER_FILES=${icd}
export VK_ICD_FILENAMES=${icd}
export KWIN_FORCE_SW_CURSOR=1
EOF
chmod 0644 "$STAGE/usr/lib/environment.d/50-mesa-guest.conf" "$STAGE/etc/profile.d/50-mesa-guest.sh"

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
 needs in /usr/lib/environment.d, /etc/profile.d and a marked block in
 /etc/environment, so a desktop comes up without any manual setup -- the last of
 those is what reaches a display-manager greeter, which is a PAM session rather
 than a systemd user session.
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
KWIN_FORCE_SW_CURSOR=1
# END mesa-guest-${V}
ENVEOF
EOF
cat > "$root/DEBIAN/postrm" <<EOF
#!/bin/sh
set -e
ldconfig
case "\$1" in remove|purge) ;; *) exit 0 ;; esac
[ -f /etc/environment ] || exit 0
sed -i '/^# BEGIN mesa-guest-${V}/,/^# END mesa-guest-${V}/d' /etc/environment
exit 0
EOF
chmod 0755 "$root/DEBIAN/postinst" "$root/DEBIAN/postrm"

deb="${pkg}_${PKGVER}_arm64.deb"
dpkg-deb --root-owner-group --build "$root" "$OUT/$deb"
echo "wrote $deb (variant $V, ICD $icd)"
