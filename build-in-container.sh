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

# One build directory per TARGET, not one per source tree. The Ubuntu cross build and the Fedora
# emulated build use different compilers, different sysroots and different dependency versions
# against the same worktree; sharing a directory makes meson reconfigure back and forth on every
# switch, and a stale object from the other toolchain is a link error with no obvious cause.
BUILDDIR=${MESA_BUILDDIR:-build-cross}
INSTDIR=${MESA_INSTDIR:-install-cross}

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
[ -z "${MESA_CLEAN:-}" ] || rm -rf "$BUILDDIR" "$INSTDIR"
if [ -d "$BUILDDIR" ]; then
    meson setup --reconfigure "$BUILDDIR" "${cross[@]}" \
        "${MESA_COMMON_MESON[@]}" $(mesa_variant_meson "$V")
else
    meson setup "$BUILDDIR" "${cross[@]}" \
        "${MESA_COMMON_MESON[@]}" $(mesa_variant_meson "$V")
fi

# The whole point of -Dglvnd=enabled is that both variants agree; a silent fallback to the
# non-GLVND layout would put a differently-shaped libEGL in the guest and only show up later.
grep -Eq 'GLVND[[:space:]]*:[[:space:]]*YES' "$BUILDDIR/meson-logs/meson-log.txt" || {
    echo "error: meson did not enable GLVND" >&2; exit 1; }

ninja -C "$BUILDDIR"
rm -rf "$INSTDIR"
DESTDIR="$PWD/$INSTDIR" ninja -C "$BUILDDIR" install

# Sanity before packaging: the shipped .so's must be aarch64, not x86. Use readelf from the
# cross toolchain rather than file(1), which the image does not carry.
readelf_bin=$(command -v aarch64-linux-gnu-readelf || command -v readelf || true)
so=$(find "$INSTDIR" -name '*.so*' -type f | head -1)
if [ -n "$readelf_bin" ]; then
    "$readelf_bin" -h "$so" | grep -q 'AArch64' || {
        echo "error: $so is not aarch64:" >&2; "$readelf_bin" -h "$so" | grep Machine >&2; exit 1; }
    echo "arch check: $("$readelf_bin" -h "$so" | awk -F: '/Machine/{print $2}' | xargs)"
else
    echo "warning: no readelf; skipping the aarch64 check" >&2
fi
find "$INSTDIR" -type f -name 'libEGL_mesa.so*' -print -quit | grep -q . || {
    echo "error: no libEGL_mesa.so -- GLVND layout missing" >&2; exit 1; }

# Packaging is package.sh's job, for both formats, from this one staged tree. Keeping it out of
# here is what stops the deb and the rpm drifting into two subtly different products.
exec bash "${WORK_CROSS:-/work/cross}/package.sh" "$V" "$PKGVER" "${MESA_PKGFMT:-deb}" \
     "$PWD/$INSTDIR" "$OUT"
