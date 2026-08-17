#!/bin/bash
# The git-shaped half for CI: fetch ONE variant's mesa branch straight from Droid-VM/mesa and hand
# the checkout to build.sh. This is what the GitHub Actions workflow runs, and it is a plain script
# so the exact same build can be reproduced on a workstation with nothing but docker and git.
#
#   ci-build.sh <gfxstream|drm2kgsl|venus> [base-branch] [outdir]
#
#   base-branch   the branch family. The mesa branch is <base-branch>-<variant>, the same rule the
#                 meta repo applies to its own branch (mesa-variants.sh: mesa_variant_branch).
#                 Default: the branch this checkout of mesa-cross is on.
#   outdir        where the .deb and <variant>.env land. Default: ./out
#
#   MESA_URL      the mesa remote (default https://github.com/Droid-VM/mesa.git)
#   MESA_SRC_DIR  the checkout to build (default ./mesa-<variant>). Reused as-is if it already
#                 exists -- REPORTED, never switched, like every checkout the meta repo manages.
#
# The clone is --single-branch and --filter=blob:none: every commit and tree of that branch, blobs
# only for the checked-out revision. mesa_pkg_version leads the package version with the commit
# COUNT (so apt can order builds), and a shallow clone would count 1 for every build; a partial
# clone keeps the count right at a fraction of a full clone's transfer.
#
# In the meta repo the equivalent of this file is lib_mesa_build.sh, which resolves the branch
# along the meta repo's fallback chain and keeps the variants as worktrees of one clone. CI has no
# chain to walk (the mesa branch either exists or the build is wrong) and no clone to share, so it
# is deliberately the dumber of the two.
set -euo pipefail
V=${1:?usage: ci-build.sh <gfxstream|drm2kgsl|venus> [base-branch] [outdir]}
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
source ./mesa-variants.sh

BRANCH=${2:-$(mesa_base_branch)}
[ -n "$BRANCH" ] && [ "$BRANCH" != HEAD ] || {
    echo "error: cannot tell the base branch (detached HEAD?) -- pass it as the 2nd argument" >&2; exit 1; }
OUT=${3:-$HERE/out}
MESA_URL=${MESA_URL:-https://github.com/Droid-VM/mesa.git}
SRC=${MESA_SRC_DIR:-$HERE/mesa-$V}

br=$(mesa_variant_branch "$V")
pkg=$(mesa_variant_pkg "$V")

if [ -d "$SRC" ]; then
    echo ">>> $SRC exists: on $(git -C "$SRC" rev-parse --abbrev-ref HEAD) $(git -C "$SRC" rev-parse --short HEAD), building that"
else
    echo ">>> cloning $MESA_URL @ $br -> $SRC"
    git clone --filter=blob:none --single-branch --branch "$br" "$MESA_URL" "$SRC"
fi

ver=$(mesa_pkg_version "$SRC")
sha=$(git -C "$SRC" rev-parse HEAD)
echo "==> $V: $br @ ${sha:0:12} -> ${pkg}_${ver}_arm64.deb"

mkdir -p "$OUT"
bash ./build.sh "$V" "$SRC" "$ver" "$OUT"

deb="${pkg}_${ver}_arm64.deb"
[ -f "$OUT/$deb" ] || { echo "error: build.sh produced no $OUT/$deb" >&2; exit 1; }

# What was built, for whoever assembles the release. KEY=VALUE, sourceable, one file per variant.
cat > "$OUT/$V.env" <<EOF
VARIANT=$V
MESA_BRANCH=$br
MESA_COMMIT=$sha
MESA_VERSION=$(tr -d '\n' < "$SRC/VERSION")
PKG=$pkg
PKGVER=$ver
DEB=$deb
DEB_MD5=$(md5sum "$OUT/$deb" | cut -d' ' -f1)
EOF
echo "wrote $OUT/$V.env"

# GitHub Actions: one line in the job summary, so a run's page says what it built without opening
# the log.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '| %s | `%s` | [`%s`](%s/commit/%s) | `%s` |\n' \
        "$V" "$br" "${sha:0:8}" "${MESA_URL%.git}" "$sha" "$deb" >> "$GITHUB_STEP_SUMMARY"
fi
