#!/bin/bash
# The two guest mesa builds, in one place.
#
# gfxstream's ICD talks to the host gfxstream decoder over the vulkan-command wire; drm2kgsl's
# turnip talks to virglrenderer's DRM native context over vdrm. They come from two branches of
# Droid-VM/mesa with unrelated upstreams: 26.0.3 for gfxstream, because the guest ICD and the
# host decoder are one codebase and must match, and 26.3.0-devel for drm2kgsl, which carries
# the tu/virtio work.
#
# BOTH install to /usr/local, because a guest tests one route at a time. That means their files
# collide, which is exactly why these are .deb rather than a tarball: the two packages Conflict,
# so dpkg refuses the second install instead of silently overwriting. Both ship libgallium, and
# the desktop composites through gallium rather than through the Vulkan ICD, so a silent
# overwrite shows up as a fully black VNC scanout with no error anywhere -- a failure this
# project has already paid for once.
#
# Sourced by the numbered mesa build scripts, mesa-cross/build-host.sh and (inside the container)
# mesa-cross/build-in-container.sh.

# Options both variants share. Anything that differs belongs in mesa_variant_meson.
# -Dglvnd=enabled matches the configuration Droid-VM/mesa's own CI validates; the danger is a
# mixture, not either choice, so both variants take it.
MESA_COMMON_MESON=(
    --buildtype release
    --prefix /usr/local
    --libdir lib/aarch64-linux-gnu
    -Dplatforms=x11,wayland
    -Dgallium-drivers=zink
    -Dopengl=true -Dgbm=enabled -Dglx=dri -Degl=enabled
    -Dglvnd=enabled
    -Dshader-cache-default=true
    -Dvulkan-manifest-per-architecture=true
    -Dallow-fallback-for=perfetto
)

# The mesa branch for a variant is THIS repo's branch plus the variant suffix, rather than a
# hardcoded pair. The two repos move together -- a meta branch describes which mesa to build, so
# hardcoding the mesa branch means a new meta branch silently keeps building the old mesa.
#
# Any variant suffix already on the meta branch is stripped first, so running this from
# wip/3d-accel-gfxstream asks for wip/3d-accel-gfxstream, not ...-gfxstream-gfxstream.
mesa_base_branch() {
    local b=${BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null)}
    b=${b%-gfxstream}; b=${b%-drm2kgsl}; b=${b%-kgsl}; b=${b%-venus}
    printf '%s' "$b"
}

mesa_variant_branch() {
    case $1 in
        gfxstream|drm2kgsl|venus) echo "$(mesa_base_branch)-$1" ;;
        *) echo "unknown mesa variant: $1" >&2; return 1 ;;
    esac
}

# Driver selection. gfxstream: the guest ICD that pairs with the host decoder. drm2kgsl: real
# turnip reaching the GPU through virtio (msm kept alongside so the same build also runs on bare
# metal for an A/B). The variant is named for the host translation, not for the guest driver:
# turnip here speaks msm over vdrm and never touches a KGSL device of its own.
mesa_variant_meson() {
    case $1 in
        gfxstream) echo "-Dvulkan-drivers=gfxstream" ;;
        drm2kgsl)      echo "-Dvulkan-drivers=freedreno -Dfreedreno-kmds=msm,virtio" ;;
        venus)         echo "-Dvulkan-drivers=virtio" ;;
        *) echo "unknown mesa variant: $1" >&2; return 1 ;;
    esac
}

mesa_variant_pkg()  { echo "mesa-guest-$1"; }

# Every package name a guest might already have installed from this family, EXCLUDING $1.
# Emitted into the deb's Conflicts and Replaces so installing one variant removes the other
# rather than overwriting its files behind dpkg's back.
#
# mesa-guest-kgsl is the pre-rename name of the drm2kgsl package. It is listed because guests
# provisioned before the rename still carry it, and a stale copy is not harmless: the two
# variants share 60 install paths but not all of them, so the leftovers of the loser stay on
# disk -- and something that picks a route by asking whether a file exists then picks the wrong
# one. That is not hypothetical; the benchmark harness chose the drm2kgsl launcher under
# gfxstream exactly that way.
mesa_variant_siblings() {
    local self=$1 out=()
    local all=(mesa-guest-gfxstream mesa-guest-drm2kgsl mesa-guest-kgsl mesa-guest-venus)
    for p in "${all[@]}"; do
        [ "$p" = "mesa-guest-$self" ] || out+=("$p")
    done
    (IFS=,; echo "${out[*]}")
}
mesa_variant_icd()  {
    case $1 in
        gfxstream) echo "/usr/local/share/vulkan/icd.d/gfxstream_vk_icd.aarch64.json" ;;
        drm2kgsl)      echo "/usr/local/share/vulkan/icd.d/freedreno_icd.aarch64.json" ;;
        venus)         echo "/usr/local/share/vulkan/icd.d/virtio_icd.aarch64.json" ;;
    esac
}

# mesa_worktree <variant> -- print the path to a checkout of that variant's branch, creating a
# git worktree beside the main mesa/ checkout if needed. One clone, two trees: the branches share
# no history, so a single checkout would have to be re-switched (and fully rebuilt) between them.
mesa_worktree() {
    local v=$1 br dir
    br=$(mesa_variant_branch "$v") || return 1
    dir="mesa-$v"
    if [ ! -d "$dir" ]; then
        git -C mesa fetch -q origin "$br:refs/remotes/origin/$br" 2>/dev/null || true
        git -C mesa worktree add -f "../$dir" "$br" >&2
    fi
    echo "$dir"
}

# mesa_pkg_version <worktree> -- upstream mesa version + the commit it was built from, so a deb
# on a guest can be traced back to a tree. git is not usable inside the container (a worktree's
# .git is a file naming an absolute host path), so this runs on the host and is passed in.
#
# A commit count leads and the hash only identifies. A hash does not order: "+droidvm.cea49934" is
# LOWER than "+droidvm.f80a84b5" whichever was built first, so installing a newer build needed
# --allow-downgrades and apt would happily keep the older one. A count of commits only goes up, on
# a branch that is never rewritten.
#
# The "r" is not decoration. Without it the new scheme would sort BELOW the old one already on
# guests -- dpkg compares the letters of "cea49934" against the empty run in front of "250" and
# letters win -- so every guest would need one more --allow-downgrades. A hash is hex, so it
# starts with 0-9 or a-f; any letter after 'f' beats all of them and the transition is ordinary.
#
# The dirty suffix exists because an uncommitted change otherwise rebuilds to the same filename
# with different contents. It sorts after that commit's clean build and before the next commit.
mesa_pkg_version() {
    local dir=$1 ver count sha dirty=""
    ver=$(tr -d '\n' < "$dir/VERSION")
    count=$(git -C "$dir" rev-list --count HEAD 2>/dev/null || echo 0)
    sha=$(git -C "$dir" rev-parse --short=8 HEAD 2>/dev/null || echo unknown)
    git -C "$dir" diff --quiet HEAD -- 2>/dev/null || dirty="+dirty$(LC_ALL=C date -u '+%Y%m%d%H%M%S')"
    echo "${ver}+droidvm.r${count}.g${sha}${dirty}"
}
