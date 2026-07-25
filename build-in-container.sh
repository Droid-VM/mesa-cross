#!/bin/bash
# Runs INSIDE the cross container (droidvm-mesa-cross). Bind mounts:
#   /work/mesa  = mesa source     /work/cross = this dir     /work/out = repo root
# Cross-compiles mesa (native x86 -> aarch64) with the SAME meson options as the
# native 8_build_guest_mesa.sh, producing an identical mesa-guest-aarch64.tar.gz.
set -e
cd /work/mesa

# Resolve every dependency against the arm64 packages only.
export PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig

rm -rf build-cross
meson setup build-cross \
    --cross-file /work/cross/aarch64-linux-gnu.meson \
    --buildtype release \
    --prefix /usr/local \
    --libdir lib/aarch64-linux-gnu \
    -Dplatforms=x11,wayland \
    -Dvulkan-drivers=gfxstream \
    -Dgallium-drivers=zink \
    -Dopengl=true -Dgbm=enabled -Dglx=dri -Degl=enabled \
    -Dshader-cache-default=true \
    -Dvulkan-manifest-per-architecture=true \
    -Dallow-fallback-for=perfetto

ninja -C build-cross
rm -rf install-cross
DESTDIR="$PWD/install-cross" ninja -C build-cross install

tar -czf /work/out/mesa-guest-aarch64.tar.gz -C install-cross .
echo "wrote mesa-guest-aarch64.tar.gz"

# Sanity: the shipped .so's must be aarch64, not x86.
so=$(find install-cross -name '*.so' | head -1)
echo "arch check: $(file -b "$so" 2>/dev/null | cut -d, -f1-2)"
