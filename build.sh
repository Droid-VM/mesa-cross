#!/bin/bash
# Build ONE guest mesa variant from a checkout that already exists, and write the .deb.
#
#   build.sh <gfxstream|drm2kgsl|venus> <mesa-path> <version> <outdir>
#
# This half knows nothing about git. It is handed a path, and whether that path is a worktree, a
# clone, a symlink or a tarball extraction is not its business -- branch resolution and checkout
# belong to the callers: the meta repo's numbered scripts (lib_mesa_build.sh) and ci-build.sh.
# Keeping the split there means the build environment can be understood without any knowledge of
# branch policy, and a build can be reproduced against an arbitrary tree by pointing this at it.
#
# CROSS ONLY: native x86 compiler emitting aarch64 against Debian multiarch arm64 -dev packages,
# no qemu, minutes rather than hours. Debian's own archive builds arm64 natively on arm64 buildds
# (a cross build skips the test suite, so it is not archive-grade), but these packages install to
# /usr/local and run no test suite, so cross is both correct here and much faster.
#
#   MESA_IMG=<tag>          image name (default droidvm-mesa-cross)
#   MESA_NO_IMAGE_BUILD=1   use $MESA_IMG as it is instead of (re)building it here. CI builds the
#                           image with a layer cache and then calls this; locally, docker's own
#                           cache makes the rebuild a no-op, so there is no reason to set it.
#   BASE=<image>            base image for the environment (default ubuntu:26.04)
#   MESA_CLEAN=1            throw the kept build dir away first (see build-in-container.sh)
set -e
V=${1:?usage: build.sh <gfxstream|drm2kgsl|venus> <mesa-path> <version> <outdir>}
SRC=${2:?missing mesa path}
VER=${3:?missing version}
OUTDIR=${4:?missing outdir}
HERE=$(cd "$(dirname "$0")" && pwd)
IMG=${MESA_IMG:-droidvm-mesa-cross}

[ -d "$SRC" ] || { echo "error: no such mesa checkout: $SRC" >&2; exit 1; }
SRC=$(cd "$SRC" && pwd)
mkdir -p "$OUTDIR"
OUTDIR=$(cd "$OUTDIR" && pwd)

if [ -n "${MESA_NO_IMAGE_BUILD:-}" ]; then
    echo "==> using cross env image $IMG as is (MESA_NO_IMAGE_BUILD)"
    docker image inspect "$IMG" >/dev/null 2>&1 || { echo "error: no image $IMG" >&2; exit 1; }
else
    echo "==> building cross env image ($IMG, base ${BASE:-ubuntu:26.04})"
    # --network=host: BuildKit runs RUN steps in its own network namespace, where DNS resolution
    # of archive.ubuntu.com/ports.ubuntu.com intermittently fails on some hosts even though a
    # plain `docker run` resolves them fine. The symptom is a wall of apt "Temporary failure
    # resolving" followed by "Unable to fetch some archives", which reads like a mirror outage.
    docker build --network=host -t "$IMG" --build-arg BASE="${BASE:-ubuntu:26.04}" \
        -f "$HERE/Dockerfile.mesa-cross" "$HERE"
fi

echo "==> cross-building mesa variant '$V'"
# Three mounts, three roles: the source tree, this directory (the build recipe AND
# mesa-variants.sh, the one place the variants' meson options are written down), and the output
# directory. The .deb goes to its own mount so the output location is an argument rather than
# "wherever the recipe happens to live".
#
# git is deliberately not usable in there: a worktree's .git is a file naming an absolute host
# path. mesa takes its version from the VERSION file, and the package version is passed in.
docker run --rm \
    -e MESA_CLEAN="${MESA_CLEAN:-}" \
    -v "$SRC:/work/mesa" \
    -v "$HERE:/work/cross:ro" \
    -v "$OUTDIR:/work/deb" \
    "$IMG" bash /work/cross/build-in-container.sh "$V" "$VER"
