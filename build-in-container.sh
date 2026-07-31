#!/bin/bash
# Configure, build and package ONE guest mesa variant. This is the single implementation of
# those three steps; 8_build_guest_mesa_cross.sh runs it inside the cross container and
# 8_build_guest_mesa.sh runs it directly on an aarch64 box, so the two paths cannot drift.
#
# Cross (default), bind mounts:
#   /work/mesa = the variant's worktree   /work/cross = this dir   /work/out = repo root
# Native: set MESA_NATIVE=1, WORK_MESA=<worktree> and WORK_OUT=<repo root>; no cross file.
#
#   build-in-container.sh <gfxstream|drm2kgsl> <package-version>
set -e
V=${1:?usage: build-in-container.sh <gfxstream|drm2kgsl> <package-version>}
PKGVER=${2:?missing package version}
OUT=${WORK_OUT:-/work/out}
SRC=${WORK_MESA:-/work/mesa}
source "$OUT/mesa-variants.sh"

cd "$SRC"

pkg=$(mesa_variant_pkg "$V")
# Naming the siblings, not just the shared virtual package, is what makes dpkg REMOVE the other
# variant instead of refusing (Conflicts alone) or silently overwriting it (what --force-all did).
# Conflicts + Replaces on a real package name is the "this supersedes that" pair.
siblings=$(mesa_variant_siblings "$V")
deb="${pkg}_${PKGVER}_arm64.deb"

if [ -n "${MESA_NATIVE:-}" ]; then
    cross=()
else
    # Resolve every dependency against the arm64 packages only.
    export PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig
    cross=(--cross-file "${WORK_CROSS:-/work/cross}/aarch64-linux-gnu.meson")
fi

# meson reconfigures itself when the options change, so keep the build dir by default --
# a failed packaging step should not cost a full rebuild. MESA_CLEAN=1 forces a fresh one.
[ -z "${MESA_CLEAN:-}" ] || rm -rf build-cross install-cross
if [ -d build-cross ]; then
    meson setup --reconfigure build-cross "${cross[@]}" \
        "${MESA_COMMON_MESON[@]}" $(mesa_variant_meson "$V")
else
    meson setup build-cross "${cross[@]}" \
        "${MESA_COMMON_MESON[@]}" $(mesa_variant_meson "$V")
fi

# The whole point of -Dglvnd=enabled is that both variants agree; a silent fallback to the
# non-GLVND layout would put a differently-shaped libEGL in the guest and only show up later.
grep -Eq 'GLVND[[:space:]]*:[[:space:]]*YES' build-cross/meson-logs/meson-log.txt || {
    echo "error: meson did not enable GLVND" >&2; exit 1; }

ninja -C build-cross
rm -rf install-cross
DESTDIR="$PWD/install-cross" ninja -C build-cross install

# Sanity before packaging: the shipped .so's must be aarch64, not x86. Use readelf from the
# cross toolchain rather than file(1), which the image does not carry.
readelf_bin=$(command -v aarch64-linux-gnu-readelf || command -v readelf || true)
so=$(find install-cross -name '*.so*' -type f | head -1)
if [ -n "$readelf_bin" ]; then
    "$readelf_bin" -h "$so" | grep -q 'AArch64' || {
        echo "error: $so is not aarch64:" >&2; "$readelf_bin" -h "$so" | grep Machine >&2; exit 1; }
    echo "arch check: $("$readelf_bin" -h "$so" | awk -F: '/Machine/{print $2}' | xargs)"
else
    echo "warning: no readelf; skipping the aarch64 check" >&2
fi
find install-cross -type f -name 'libEGL_mesa.so*' -print -quit | grep -q . || {
    echo "error: no libEGL_mesa.so -- GLVND layout missing" >&2; exit 1; }

# Both variants install to /usr/local and therefore collide. Conflicts/Replaces naming the OTHER
# variants makes dpkg remove the previous one rather than overwriting the first:
# both ship libgallium, the desktop composites through gallium rather than the Vulkan ICD, and
# the overwrite is invisible until the whole screen is black.
# Ship the environment this build needs instead of leaving it to whoever installs the package.
#
# MESA_LOADER_DRIVER_OVERRIDE is not optional and not a tuning knob. Both variants are built
# -Dgallium-drivers=zink, so neither ships a driver named for the guest's kernel driver; the DRI
# names in dri/ are all symlinks to libdril_dri.so, and pipe_loader then picks the pipe driver
# from the kernel driver name -- virgl for virtio_gpu, which is not built here. Without the
# override GNOME Shell gets "virtio_gpu: driver missing", falls back to kms_swrast, and fails with
# "Failed to setup: No GPUs found", so gdm retries the greeter until it gives up. Vulkan works the
# whole time, which is what makes it look like a gdm fault.
#
# VK_DRIVER_FILES is not strictly required -- the loader already searches /usr/local/share/vulkan
# -- but pinning it keeps the distro's software ICDs (lavapipe) out of the enumeration. An app
# quietly choosing llvmpipe is slow rather than broken, which is the hardest kind of regression to
# notice.
#
# Two files because they cover different entry points, and neither is a conffile the admin owns:
# environment.d reaches systemd user sessions (the gdm greeter, GNOME, anything the session
# starts), profile.d reaches shell logins. Editing /etc/environment from a script covers both but
# is the admin's file, and a sed that rewrites it can drop a line it did not put there.
icd=$(mesa_variant_icd "$V")
install -d -m 0755 install-cross/usr/lib/environment.d install-cross/etc/profile.d
cat > install-cross/usr/lib/environment.d/50-mesa-guest.conf <<EOF
# Installed by ${pkg}. See /usr/share/doc/${pkg}.
MESA_LOADER_DRIVER_OVERRIDE=zink
VK_DRIVER_FILES=${icd}
VK_ICD_FILENAMES=${icd}
EOF
cat > install-cross/etc/profile.d/50-mesa-guest.sh <<EOF
# Installed by ${pkg}.
export MESA_LOADER_DRIVER_OVERRIDE=zink
export VK_DRIVER_FILES=${icd}
export VK_ICD_FILENAMES=${icd}
EOF
chmod 0644 install-cross/usr/lib/environment.d/50-mesa-guest.conf \
           install-cross/etc/profile.d/50-mesa-guest.sh

install -d -m 0755 install-cross/DEBIAN
installed_size=$(du -sk install-cross | cut -f1)
cat > install-cross/DEBIAN/control <<EOF
Package: ${pkg}
Version: ${PKGVER}
Section: libs
Priority: optional
Architecture: arm64
Installed-Size: ${installed_size}
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
cat > install-cross/DEBIAN/postinst <<'EOF'
#!/bin/sh
set -e
ldconfig
EOF
cat > install-cross/DEBIAN/postrm <<'EOF'
#!/bin/sh
set -e
ldconfig
EOF
chmod 0755 install-cross/DEBIAN/postinst install-cross/DEBIAN/postrm

dpkg-deb --root-owner-group --build install-cross "$OUT/$deb"
echo "wrote $deb (variant $V, ICD $(mesa_variant_icd "$V"))"
