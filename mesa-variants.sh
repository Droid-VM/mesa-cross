#!/bin/bash
# The two guest mesa builds, in one place.
#
# The guest ships BOTH: gfxstream's ICD talks to the host gfxstream decoder over the
# vulkan-command wire, kgsl's turnip talks to virglrenderer's DRM native context over
# vdrm. They come from two branches of Droid-VM/mesa with unrelated upstreams (26.0.3
# for gfxstream, because the guest ICD and the host decoder are one codebase and must
# match; 26.3.0-devel for kgsl, which carries the tu/virtio work).
#
# They install to DIFFERENT PREFIXES on purpose. Both provide libgallium, libEGL and a
# vulkan ICD manifest, and mutter composites through gallium rather than through the
# Vulkan ICD -- so two stacks in one prefix means the desktop silently picks up whichever
# libgallium landed last. That failure is a fully black VNC scanout with no error, and it
# has already cost one debugging session. gfxstream keeps /usr/local (where every existing
# guest already has it); kgsl is confined to /opt/mesa-kgsl and selected by environment.
#
# Sourced by 8_build_guest_mesa.sh, 8_build_guest_mesa_cross.sh and (inside the container)
# mesa-cross/build-in-container.sh.

# Options both variants share. Anything that differs belongs in mesa_variant_meson.
MESA_COMMON_MESON=(
    --buildtype release
    --libdir lib/aarch64-linux-gnu
    -Dplatforms=x11,wayland
    -Dgallium-drivers=zink
    -Dopengl=true -Dgbm=enabled -Dglx=dri -Degl=enabled
    -Dshader-cache-default=true
    -Dvulkan-manifest-per-architecture=true
    -Dallow-fallback-for=perfetto
)

mesa_variant_branch() {
    case $1 in
        gfxstream) echo wip/3d-accel-gfxstream ;;
        kgsl)      echo wip/3d-accel-kgsl ;;
        *) echo "unknown mesa variant: $1" >&2; return 1 ;;
    esac
}

mesa_variant_prefix() {
    case $1 in
        gfxstream) echo /usr/local ;;
        kgsl)      echo /opt/mesa-kgsl ;;
        *) echo "unknown mesa variant: $1" >&2; return 1 ;;
    esac
}

# Driver selection. gfxstream: the guest ICD that pairs with the host decoder. kgsl: real
# turnip reaching the GPU through virtio (msm kept alongside virtio so the same build also
# runs on bare metal for A/B).
mesa_variant_meson() {
    case $1 in
        gfxstream) echo "-Dvulkan-drivers=gfxstream" ;;
        kgsl)      echo "-Dvulkan-drivers=freedreno -Dfreedreno-kmds=msm,virtio" ;;
        *) echo "unknown mesa variant: $1" >&2; return 1 ;;
    esac
}

mesa_variant_tarball() { echo "mesa-guest-$1-aarch64.tar.gz"; }

# Which variants to build. MESA_VARIANT wins; otherwise the meta repo's branch decides,
# and the trunk builds both because the guest installs both.
mesa_variants() {
    if [ -n "${MESA_VARIANT:-}" ]; then
        echo "$MESA_VARIANT"
        return
    fi
    case "${BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null)}" in
        *-gfxstream) echo gfxstream ;;
        *-kgsl)      echo kgsl ;;
        *)           echo "gfxstream kgsl" ;;
    esac
}

# mesa_worktree <variant> -- print the path to a checkout of that variant's branch,
# creating a git worktree beside the main mesa/ checkout if needed. One clone, two trees:
# the branches share no history, so a single checkout would have to be re-switched (and
# fully rebuilt) between variants.
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
