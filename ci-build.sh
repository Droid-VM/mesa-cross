#!/bin/bash
# The git-shaped half for CI: fetch the mesa branch straight from Droid-VM/mesa and hand the
# checkout to build.sh. This is what the GitHub Actions workflow runs, and it is a plain script so
# the exact same build can be reproduced on a workstation with nothing but docker and git.
#
#   ci-build.sh [branch] [outdir]
#
#   branch   the Droid-VM/mesa branch to build. Default: the branch this checkout of mesa-cross is
#            on (the repos move together, so a mesa-cross branch describes which mesa goes with
#            it). A variant suffix left over from before the three routes merged is stripped.
#   outdir   where the .deb and build.env land. Default: ./out
#
#   MESA_URL      the mesa remote (default https://github.com/Droid-VM/mesa.git)
#   MESA_SRC_DIR  the checkout to build (default ./mesa). Reused as-is if it already exists --
#                 REPORTED, never switched, like every checkout the meta repo manages.
#
# The clone is --single-branch and --filter=blob:none: every commit and tree of that branch, blobs
# only for the checked-out revision. mesa_pkg_version leads the package version with the commit
# COUNT (so apt can order builds), and a shallow clone would count 1 for every build; a partial
# clone keeps the count right at a fraction of a full clone's transfer.
#
# In the meta repo the equivalent of this file is lib_mesa_build.sh, which resolves the branch
# along the meta repo's fallback chain. CI has no chain to walk (the mesa branch either exists or
# the build is wrong), so it is deliberately the dumber of the two.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
source ./mesa-config.sh

BRANCH=${1:-$(mesa_branch)}
[ -n "$BRANCH" ] && [ "$BRANCH" != HEAD ] || {
    echo "error: cannot tell the branch (detached HEAD?) -- pass it as the 1st argument" >&2; exit 1; }
OUT=${2:-$HERE/out}
MESA_URL=${MESA_URL:-https://github.com/Droid-VM/mesa.git}
SRC=${MESA_SRC_DIR:-$HERE/mesa}

if [ -d "$SRC" ]; then
    echo ">>> $SRC exists: on $(git -C "$SRC" rev-parse --abbrev-ref HEAD) $(git -C "$SRC" rev-parse --short HEAD), building that"
else
    echo ">>> cloning $MESA_URL @ $BRANCH -> $SRC"
    git clone --filter=blob:none --single-branch --branch "$BRANCH" "$MESA_URL" "$SRC"
fi

ver=$(mesa_pkg_version "$SRC")
sha=$(git -C "$SRC" rev-parse HEAD)
echo "==> $BRANCH @ ${sha:0:12} -> ${MESA_PKG}_${ver}_arm64.deb"

mkdir -p "$OUT"
bash ./build.sh "$SRC" "$ver" "$OUT"

deb="${MESA_PKG}_${ver}_arm64.deb"
[ -f "$OUT/$deb" ] || { echo "error: build.sh produced no $OUT/$deb" >&2; exit 1; }

# What was built, for whoever assembles the release. KEY=VALUE, sourceable.
cat > "$OUT/build.env" <<ENVEOF
MESA_BRANCH=$BRANCH
MESA_COMMIT=$sha
MESA_VERSION=$(tr -d '\n' < "$SRC/VERSION")
PKG=$MESA_PKG
PKGVER=$ver
DEB=$deb
DEB_MD5=$(md5sum "$OUT/$deb" | cut -d' ' -f1)
ENVEOF
echo "wrote $OUT/build.env"

# GitHub Actions: one line in the job summary, so a run's page says what it built without opening
# the log.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '| `%s` | [`%s`](%s/commit/%s) | `%s` |\n' \
        "$BRANCH" "${sha:0:8}" "${MESA_URL%.git}" "$sha" "$deb" >> "$GITHUB_STEP_SUMMARY"
fi
