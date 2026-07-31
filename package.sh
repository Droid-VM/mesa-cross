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
# Environment, identical in both formats.
#
# Two files because they cover different entry points, and neither is a conffile the admin owns:
# environment.d reaches systemd user sessions (the gdm greeter, GNOME, anything the session
# starts), profile.d reaches shell logins. Editing /etc/environment would cover both but is the
# admin's file, and a sed that rewrites it can drop a line it did not put there.
#
# VK_DRIVER_FILES is not strictly required -- the loader already searches /usr/local/share/vulkan
# -- but pinning it keeps the distro's software ICDs (lavapipe) out of the enumeration. An app
# quietly choosing llvmpipe is slow rather than broken, which is the hardest kind of regression to
# notice.
# ---------------------------------------------------------------------------
install -d -m 0755 "$STAGE/usr/lib/environment.d" "$STAGE/etc/profile.d"
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
 needs (MESA_LOADER_DRIVER_OVERRIDE, VK_DRIVER_FILES) in /usr/lib/environment.d
 and /etc/profile.d, so a desktop comes up without any manual setup.
 .
 Only one mesa-guest-* package can be installed at a time: they share a prefix.
EOF
printf '#!/bin/sh\nset -e\nldconfig\n' > "$root/DEBIAN/postinst"
printf '#!/bin/sh\nset -e\nldconfig\n' > "$root/DEBIAN/postrm"
chmod 0755 "$root/DEBIAN/postinst" "$root/DEBIAN/postrm"

deb="${pkg}_${PKGVER}_arm64.deb"
dpkg-deb --root-owner-group --build "$root" "$OUT/$deb"
echo "wrote $deb (variant $V, ICD $icd)"
