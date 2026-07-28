#!/bin/bash
# Runs INSIDE the cross container (droidvm-mesa-cross). Bind mounts:
#   /work/mesa  = mesa source for ONE variant   /work/cross = this dir   /work/out = repo root
# Cross-compiles mesa (native x86 -> aarch64) with the SAME meson options as the native
# 8_build_guest_mesa.sh -- both read them from mesa-variants.sh, so there is one list.
#
# The caller passes the variant and bind-mounts that variant's worktree at /work/mesa.
set -e
V=${1:?usage: build-in-container.sh <gfxstream|kgsl>}
source /work/out/mesa-variants.sh

cd /work/mesa

# Resolve every dependency against the arm64 packages only.
export PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig

prefix=$(mesa_variant_prefix "$V")
tarball=$(mesa_variant_tarball "$V")

rm -rf build-cross
meson setup build-cross \
    --cross-file /work/cross/aarch64-linux-gnu.meson \
    --prefix "$prefix" \
    "${MESA_COMMON_MESON[@]}" $(mesa_variant_meson "$V")

ninja -C build-cross
rm -rf install-cross
DESTDIR="$PWD/install-cross" ninja -C build-cross install

tar -czf "/work/out/$tarball" -C install-cross .
echo "wrote $tarball (variant $V, prefix $prefix)"

# Sanity: the shipped .so's must be aarch64, not x86.
so=$(find install-cross -name '*.so' | head -1)
echo "arch check: $(file -b "$so" 2>/dev/null | cut -d, -f1-2)"
