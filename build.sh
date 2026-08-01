#!/bin/bash
# Build ONE guest mesa variant from a checkout that already exists, and write the .deb.
#
#   mesa-cross/build.sh <gfxstream|drm2kgsl> <mesa-path> <version> <outdir>
#
# This half knows nothing about git. It is handed a path, and whether that path is a worktree, a
# clone, a symlink or a tarball extraction is not its business -- branch resolution and checkout
# belong to the numbered scripts (lib_mesa_build.sh). Keeping the split there means the build
# environment can be understood without any knowledge of branch policy, and a build can be
# reproduced against an arbitrary tree by pointing this at it.
#
# CROSS ONLY: native x86 compiler emitting aarch64 against Debian multiarch arm64 -dev packages,
# no qemu, minutes rather than hours. Debian's own archive builds arm64 natively on arm64 buildds
# (a cross build skips the test suite, so it is not archive-grade), but these packages install to
# /usr/local and run no test suite, so cross is both correct here and much faster.
set -e
V=${1:?usage: build.sh <gfxstream|drm2kgsl> <mesa-path> <version> <outdir>}
SRC=${2:?missing mesa path}
VER=${3:?missing version}
OUTDIR=${4:?missing outdir}
REPO=$(cd "$(dirname "$0")/.." && pwd)
IMG=${MESA_IMG:-droidvm-mesa-cross}

[ -d "$SRC" ] || { echo "error: no such mesa checkout: $SRC" >&2; exit 1; }
mkdir -p "$OUTDIR"

echo "==> building cross env image ($IMG, base ${BASE:-ubuntu:26.04})"
# --network=host: BuildKit runs RUN steps in its own network namespace, where DNS resolution of
# archive.ubuntu.com/ports.ubuntu.com intermittently fails on this host even though a plain
# `docker run` resolves them fine. The symptom is a wall of apt "Temporary failure resolving"
# followed by "Unable to fetch some archives", which reads like a mirror outage.
docker build --network=host -t "$IMG" --build-arg BASE="${BASE:-ubuntu:26.04}" \
    -f "$REPO/mesa-cross/Dockerfile.mesa-cross" "$REPO/mesa-cross"

echo "==> cross-building mesa variant '$V'"
# Three mounts, three roles: the source tree, this directory's build recipe, and the repo root --
# the last only so the container can read mesa-variants.sh, which is the one place the two
# variants' meson options are written down. The .deb goes to its own mount so the output location
# is an argument rather than "wherever /work/out happens to be".
#
# git is deliberately not usable in there: a worktree's .git is a file naming an absolute host
# path. mesa takes its version from the VERSION file, and the package version is passed in.
docker run --rm \
    -v "$SRC:/work/mesa" \
    -v "$REPO/mesa-cross:/work/cross" \
    -v "$REPO:/work/out:ro" \
    -v "$OUTDIR:/work/deb" \
    "$IMG" bash /work/cross/build-in-container.sh "$V" "$VER"
