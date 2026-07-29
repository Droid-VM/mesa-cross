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
# Sourced by 8_build_guest_mesa.sh, 8_build_guest_mesa_cross.sh and (inside the container)
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

mesa_variant_branch() {
    case $1 in
        gfxstream) echo wip/3d-accel-gfxstream ;;
        drm2kgsl)      echo wip/3d-accel-drm2kgsl ;;
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
        *) echo "unknown mesa variant: $1" >&2; return 1 ;;
    esac
}

mesa_variant_pkg()  { echo "mesa-guest-$1"; }
mesa_variant_icd()  {
    case $1 in
        gfxstream) echo "/usr/local/share/vulkan/icd.d/gfxstream_vk_icd.aarch64.json" ;;
        drm2kgsl)      echo "/usr/local/share/vulkan/icd.d/freedreno_icd.aarch64.json" ;;
    esac
}

# Which variants to build. MESA_VARIANT wins; otherwise the meta repo's branch decides, and the
# trunk builds both because both debs are wanted even though only one is installed at a time.
mesa_variants() {
    if [ -n "${MESA_VARIANT:-}" ]; then
        echo "$MESA_VARIANT"
        return
    fi
    case "${BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null)}" in
        *-gfxstream) echo gfxstream ;;
        *-drm2kgsl)      echo drm2kgsl ;;
        *)           echo "gfxstream drm2kgsl" ;;
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
mesa_pkg_version() {
    local dir=$1 ver sha
    ver=$(tr -d '\n' < "$dir/VERSION")
    sha=$(git -C "$dir" rev-parse --short=8 HEAD 2>/dev/null || echo unknown)
    echo "${ver}+droidvm.${sha}"
}
