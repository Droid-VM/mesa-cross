#!/bin/bash
# Host side of ONE guest mesa variant build: check out that variant's mesa branch, build the
# cross image, run the build in it, and put the .deb where the deploy step looks for it.
#
#   mesa-cross/build-host.sh <gfxstream|drm2kgsl>
#
# Invoked by 8_build_guest_mesa_gfx.sh and 8_build_guest_mesa_drm2kgsl.sh, which exist so the
# flow reads as a sequence of numbered steps. Both call this, so the two variants cannot drift
# apart in how they are checked out, built or packaged -- only in the meson options that make
# them different routes (see mesa-variants.sh).
#
# CROSS ONLY. Native x86 compiler emitting aarch64 against Debian multiarch arm64 -dev packages;
# no qemu anywhere, minutes rather than hours. Debian's official archive builds arm64 natively on
# arm64 buildds (a cross build skips the test suite, so it is not archive-grade), but these
# packages install to /usr/local and run no test suite, so cross is both correct and much faster.
set -e
cd "$(dirname "$0")/.."
V=${1:?usage: build-host.sh <gfxstream|drm2kgsl>}
source ./lib_branch.sh
source ./mesa-variants.sh
source ./lib_dist.sh
IMG=droidvm-mesa-cross

case $V in gfxstream|drm2kgsl) ;; *) echo "error: unknown variant '$V'" >&2; exit 2 ;; esac
command -v docker >/dev/null || { echo "error: docker required" >&2; exit 1; }

clone_at mesa https://github.com/Droid-VM/mesa.git

echo "==> building cross env image ($IMG, base ${BASE:-ubuntu:26.04})"
# --network=host: BuildKit runs RUN steps in its own network namespace, where DNS resolution of
# archive.ubuntu.com/ports.ubuntu.com intermittently fails on this host even though a plain
# `docker run` resolves them fine. The symptom is a wall of apt "Temporary failure resolving"
# followed by "Unable to fetch some archives", which reads like a mirror outage.
docker build --network=host -t "$IMG" --build-arg BASE="${BASE:-ubuntu:26.04}" \
    -f mesa-cross/Dockerfile.mesa-cross mesa-cross

src=$(mesa_worktree "$V")
echo "==> cross-building mesa variant '$V' from $src ($(mesa_variant_branch "$V"))"
# The worktree's .git is a file pointing at an absolute host path, so git is not usable inside
# the container. mesa takes its version from the VERSION file, so nothing in the build needs it.
docker run --rm \
    -v "$PWD/$src:/work/mesa" \
    -v "$PWD/mesa-cross:/work/cross" \
    -v "$PWD:/work/out" \
    "$IMG" bash /work/cross/build-in-container.sh "$V" "$(mesa_pkg_version "$src")"

deb=$(ls -t "$PWD"/$(mesa_variant_pkg "$V")_*_arm64.deb 2>/dev/null | head -1)
[ -n "$deb" ] || { echo "error: the build produced no .deb" >&2; exit 1; }
dist_add "$deb"
dist_report
