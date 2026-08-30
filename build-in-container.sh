#!/bin/bash
# Configure, build and package the guest mesa inside the cross container. One build, all three
# Vulkan drivers (gfxstream, venus, freedreno-over-vdrm), so the routes cannot drift apart in how
# they are built -- they no longer can, being the same binary.
#
# Bind mounts:
#   /work/mesa  = the mesa checkout        /work/cross = this dir (recipe + mesa-config.sh), READ-ONLY
#   /work/deb   = where the .deb goes
#
# Nothing else is mounted, so a build cannot write anywhere except its own tree and the output
# directory it was given.
#
#   build-in-container.sh <package-version>
set -e
PKGVER=${1:?usage: build-in-container.sh <package-version>}
CROSS=${WORK_CROSS:-/work/cross}
DEBOUT=${WORK_DEBOUT:-/work/deb}
SRC=${WORK_MESA:-/work/mesa}
source "$CROSS/mesa-config.sh"

cd "$SRC"


# Resolve every dependency against the arm64 packages only. Debian multiarch puts them in the
# compiler's normal search path, so this is the whole of the cross setup -- no sysroot involved.
export PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig
cross=(--cross-file "$CROSS/aarch64-linux-gnu.meson")

# meson reconfigures itself when the options change, so keep the build dir by default --
# a failed packaging step should not cost a full rebuild. MESA_CLEAN=1 forces a fresh one.
[ -z "${MESA_CLEAN:-}" ] || rm -rf build-cross install-cross
if [ -d build-cross ]; then
    meson setup --reconfigure build-cross "${cross[@]}" \
        "${MESA_MESON[@]}"
else
    meson setup build-cross "${cross[@]}" \
        "${MESA_MESON[@]}"
fi

# The whole point of -Dglvnd=enabled is a single agreed layout; a silent fallback to the
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

# Packaging is package.sh's job, from this one staged tree.
exec bash "$CROSS/package.sh" "$PKGVER" "$PWD/install-cross" "$DEBOUT"
