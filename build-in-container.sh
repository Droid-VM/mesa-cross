#!/bin/bash
# Configure, build and package ONE guest mesa variant, inside the cross container. Single
# implementation for both variants, so the two routes cannot drift apart in how they are built.
#
# Bind mounts:
#   /work/mesa  = the mesa checkout        /work/cross = this dir
#   /work/out   = repo root, READ-ONLY     /work/deb   = where the .deb goes
#
# The repo root is mounted only for mesa-variants.sh (the one place the two variants' meson
# options live) and is read-only, so a build cannot write anywhere except its own tree and the
# output directory it was given.
#
#   build-in-container.sh <gfxstream|drm2kgsl> <package-version>
set -e
V=${1:?usage: build-in-container.sh <gfxstream|drm2kgsl> <package-version>}
PKGVER=${2:?missing package version}
REPO=${WORK_OUT:-/work/out}
DEBOUT=${WORK_DEBOUT:-/work/deb}
SRC=${WORK_MESA:-/work/mesa}
source "$REPO/mesa-variants.sh"

cd "$SRC"

pkg=$(mesa_variant_pkg "$V")
# Naming the siblings, not just the shared virtual package, is what makes dpkg REMOVE the other
# variant instead of refusing (Conflicts alone) or silently overwriting it (what --force-all did).
# Conflicts + Replaces on a real package name is the "this supersedes that" pair.
siblings=$(mesa_variant_siblings "$V")
deb="${pkg}_${PKGVER}_arm64.deb"

# Resolve every dependency against the arm64 packages only. Debian multiarch puts them in the
# compiler's normal search path, so this is the whole of the cross setup -- no sysroot involved.
export PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig
cross=(--cross-file "${WORK_CROSS:-/work/cross}/aarch64-linux-gnu.meson")

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

# Packaging is package.sh's job, from this one staged tree.
exec bash "${WORK_CROSS:-/work/cross}/package.sh" "$V" "$PKGVER" "$PWD/install-cross" "$DEBOUT"
