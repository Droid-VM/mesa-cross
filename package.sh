#!/bin/bash
# Turn a staged `meson install` tree into a distro package.
#
#   package.sh <version> <stagedir> <outdir>
#
# Called by build-in-container.sh once the build is done, so the staged tree and the environment
# files it ships are described in exactly one place.
#
# What has to be true on both, and why:
#
#   * One package now carries all three routes, so nothing has to be swapped to change route.
#     The per-route packages it replaces installed to the same ~60 paths (every kmsro *_dri.so,
#     the gbm backend, libgallium), so they are named in Conflicts+Replaces: that pair makes dpkg
#     REMOVE them rather than refuse the install (Conflicts alone) or overwrite their files behind
#     dpkg's back. They all shipped libgallium, the desktop composites through gallium rather than
#     through the Vulkan ICD, and a leftover copy is invisible until the whole screen is black.
#
#     NOTHING is said about the virtual name mesa-guest any more, and that is deliberate. The
#     per-route packages carried Provides+Conflicts+Replaces on it, which is the ordinary "only one
#     provider" idiom -- but this package is NAMED mesa-guest, so providing it made the old
#     packages' `Conflicts: mesa-guest` unresolvable for dpkg: on a guest still holding
#     mesa-guest-venus, `dpkg -i` refused with "mesa-guest provides mesa-guest and is to be
#     installed / conflicting packages - not installing mesa-guest". Dropping the Provides line
#     makes the same install remove the old package instead (measured both ways in a scratch dpkg
#     root). apt was never affected -- it plans the removal itself -- but `dpkg -i` is what someone
#     reaches for when apt is not around, and its refusal names the wrong culprit.
#
#   * The environment is part of the package. MESA_LOADER_DRIVER_OVERRIDE=zink is not a tuning
#     knob -- the build is -Dgallium-drivers=zink, so without it GNOME Shell gets
#     "virtio_gpu: driver missing", falls back to kms_swrast and fails with "No GPUs found", while
#     Vulkan works the whole time and it looks like a gdm fault.
set -euo pipefail

# exec'd from build-in-container.sh, so the configuration has to be sourced again here.
source "${WORK_CROSS:-/work/cross}/mesa-config.sh"

PKGVER=${1:?version}
STAGE=${2:?stagedir}
OUT=${3:?outdir}

pkg=$MESA_PKG
siblings=$(mesa_supersedes_list)
# Every ICD, colon-separated. The loader tries each and keeps whichever enumerates a device; a
# DroidVM guest sees exactly one virtio-gpu capset, so exactly one answers.
icd=$(mesa_icd_list)

# ---------------------------------------------------------------------------
# Environment, decided at BOOT and delivered through four channels, because no single channel
# reaches every entry point and no static file can ask whether the guest has a GPU.
#
# The DECISION is new. The zink override and the pinned VK_DRIVER_FILES used to be shipped
# unconditionally, and on a guest with no paravirt GPU (simplefb-only display: no virtio-gpu,
# no render node, so none of our three ICDs can enumerate a device) they were the failure:
# zink had no Vulkan under it, GLX offered zero FBConfigs, and sddm restarted its greeter
# forever ("Could not initialize GLX", HelperExitStatus 6) -- while systemd reported zero
# failed units. The build now carries llvmpipe precisely for that guest, but llvmpipe only
# gets a chance if the override is NOT set. So mesa-guest-env.service runs once per boot,
# probes for a GPU (a virtio device with id 16 in /sys -- present as soon as virtio-pci
# binds, whether or not virtio_gpu is loaded -- or any render node, for bare-metal msm), and
# either applies the zink environment or clears it. Add the GPU to the VM and the next boot
# re-applies everything; no reinstall, nothing to remember.
#
#   probe result            GL stack that boots
#   GPU present             zink on gfxstream/venus/turnip (as before)
#   no GPU                  llvmpipe from this package, software but alive
#
# The four channels, and why each exists (measured the hard way -- see git history for the
# greeter-crash matrix that produced them):
#
#   user-environment-generators     systemd USER sessions -- GNOME, and the gdm greeter, which is
#                                   one. Was a static environment.d file; a generator is the same
#                                   channel with an if in front.
#   /etc/profile.d                  login shells. The shipped script tests the boot flag.
#   /etc/environment                PAM sessions, via pam_env -- notably display-manager greeters
#                                   that are NOT systemd user sessions (sddm-helper rebuilds its
#                                   env, so neither environment.d nor sddm.service.d reaches it).
#                                   pam_env has no drop-in directory and no conditionals, so the
#                                   boot service edits a marked block in place.
#   systemctl set-environment       systemd SYSTEM services -- above all the X server, which a
#                                   display manager spawns itself rather than through PAM: without
#                                   the override glamor fails and GLX offers the greeter no
#                                   FBConfig it will accept. Was a static system.conf.d
#                                   DefaultEnvironment= drop-in; set-environment is its runtime
#                                   equivalent, applied before display-manager.service starts,
#                                   and needs no daemon-reexec to take effect.
#
# MESA_LOADER_DRIVER_OVERRIDE is not a tuning knob. Nothing in dri/ is named for the guest's
# kernel driver, and pipe_loader asks for one named "virtio_gpu". Without the override it finds
# nothing: "QGLXContext: Failed to create dummy context", and whatever needed GL dies.
#
# VK_DRIVER_FILES lists all three of our ICDs. It keeps the distro's software ICDs (lavapipe) out
# of the enumeration -- an app quietly choosing llvmpipe is slow rather than broken, which is the
# hardest kind of regression to notice -- and it is also how the route gets chosen now: the loader
# initialises each in turn and the ones whose capset the VMM did not expose enumerate no device.
# On a GPU-less boot it is left unset, and software Vulkan (the distro's lavapipe, if installed)
# stays reachable.
#
# /etc/environment IS the admin's file, and that is why it is edited inside named markers rather
# than shipped: every writer strips every mesa-guest block before adding its own, so nothing this
# package did not write is ever touched and nothing it wrote is ever left behind.
# ---------------------------------------------------------------------------
#
# NO KWIN_FORCE_SW_CURSOR here, deliberately. It was shipped for a while because the guest's
# hardware cursor plane never reached the screen and forcing KWin to draw the pointer into the
# framebuffer was the only way to see one. The host now presents the cursor plane properly (crosvm
# composites it for VNC, and the app hosts an overlay Surface for the native path), so the
# workaround would do active harm: it stops KWin ever using the cursor plane, which makes the
# hardware path look broken and hides any regression in it. It also only ever helped Linux
# compositors -- Windows' virtio-gpu driver and UEFI have no equivalent knob.
install -d -m 0755 "$STAGE/usr/lib/mesa-guest" "$STAGE/etc/profile.d" \
                   "$STAGE/usr/lib/systemd/system" "$STAGE/usr/lib/systemd/system/multi-user.target.wants" \
                   "$STAGE/usr/lib/systemd/user-environment-generators"

# The probe and both of its consequences, in one place. Also what postinst runs -- installing is
# just "a boot happened now".
cat > "$STAGE/usr/lib/mesa-guest/mesa-guest-env" <<EOF
#!/bin/sh
# Installed by ${pkg}. Runs from mesa-guest-env.service once per boot (and from postinst):
# probes for a GPU our ICDs can drive and applies or clears the zink environment accordingly.
# GPU-less guests then fall through to this package's llvmpipe instead of crash-looping the
# greeter. MESA_GUEST_FORCE_GPU=1/0 overrides the probe, for testing either branch.
set -e

FLAG=/run/mesa-guest-gpu

gpu_present() {
    case "\${MESA_GUEST_FORCE_GPU:-}" in 1) return 0 ;; 0) return 1 ;; esac
    # A virtio device with id 16 (GPU). Read from the virtio bus, not /dev/dri: the bus entry
    # appears when virtio-pci binds (initramfs, long before this service), while the render node
    # waits for the virtio_gpu module -- a DKMS module here, so possibly still being loaded.
    for m in /sys/bus/virtio/devices/*/modalias; do
        [ -r "\$m" ] || continue
        case \$(cat "\$m") in virtio:d00000010*) return 0 ;; esac
    done
    # Bare metal (-Dfreedreno-kmds=msm builds run there too): any render node counts.
    for r in /dev/dri/renderD*; do
        [ -e "\$r" ] && return 0
    done
    return 1
}

# Built beside the target and renamed over it, never appended to in place. An append that is
# interrupted -- the VM losing power, which on this platform means the VMM crashing -- leaves the
# file extended to its new length with the tail unwritten, which on ext4 reads back as NUL bytes.
# pam_env then refuses the whole file, and the one channel that reaches a display manager's PAM
# session goes silent while the others stay correct. Seen exactly that.
write_environment() {
    umask 022
    if [ -f /etc/environment ]; then
        sed '/^# BEGIN mesa-guest/,/^# END mesa-guest/d' /etc/environment > /etc/environment.mesa-guest-new
    else
        : > /etc/environment.mesa-guest-new
    fi
    if [ "\$1" = gpu ]; then
        cat >> /etc/environment.mesa-guest-new <<'BLOCK'
# BEGIN mesa-guest (managed by mesa-guest-env at boot; edits inside this block are lost)
MESA_LOADER_DRIVER_OVERRIDE=zink
VK_DRIVER_FILES=${icd}
VK_ICD_FILENAMES=${icd}
# END mesa-guest
BLOCK
    fi
    sync /etc/environment.mesa-guest-new 2>/dev/null || true
    mv -f /etc/environment.mesa-guest-new /etc/environment
}

if gpu_present; then
    write_environment gpu
    : > "\$FLAG"
    if [ -d /run/systemd/system ]; then
        systemctl set-environment \\
            MESA_LOADER_DRIVER_OVERRIDE=zink \\
            "VK_DRIVER_FILES=${icd}" \\
            "VK_ICD_FILENAMES=${icd}"
    fi
    echo "mesa-guest-env: GPU present, zink environment applied"
else
    write_environment none
    rm -f "\$FLAG"
    if [ -d /run/systemd/system ]; then
        systemctl unset-environment MESA_LOADER_DRIVER_OVERRIDE VK_DRIVER_FILES VK_ICD_FILENAMES
    fi
    echo "mesa-guest-env: no GPU, zink environment cleared (llvmpipe fallback)"
fi
EOF
chmod 0755 "$STAGE/usr/lib/mesa-guest/mesa-guest-env"

cat > "$STAGE/usr/lib/systemd/system/mesa-guest-env.service" <<EOF
[Unit]
Description=Droid-VM guest GPU environment (zink when a GPU is present, llvmpipe otherwise)
# Both audiences start later: PAM logins are gated by systemd-user-sessions.service (so they
# read the /etc/environment this writes), and the display manager -- whose X server inherits
# the manager environment set here -- by display-manager.service. The probe reads the virtio
# bus in /sys, populated by the initramfs, so no udev settling is needed.
Before=systemd-user-sessions.service display-manager.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/lib/mesa-guest/mesa-guest-env

[Install]
WantedBy=multi-user.target
EOF
# Enabled by shipped symlink rather than postinst `systemctl enable`: static enablement cannot
# drift, survives without debhelper, and dpkg removes it with the package.
ln -s ../mesa-guest-env.service \
      "$STAGE/usr/lib/systemd/system/multi-user.target.wants/mesa-guest-env.service"

# The systemd-user-session channel. A generator instead of a static environment.d file -- same
# audience, but it can test the flag. It runs at every \`systemd --user\` startup, which is after
# the boot service by the ordering above.
cat > "$STAGE/usr/lib/systemd/user-environment-generators/50-mesa-guest" <<EOF
#!/bin/sh
# Installed by ${pkg}. Emits the zink environment iff this boot's GPU probe said so.
[ -e /run/mesa-guest-gpu ] || exit 0
cat <<'GEN'
MESA_LOADER_DRIVER_OVERRIDE=zink
VK_DRIVER_FILES=${icd}
VK_ICD_FILENAMES=${icd}
GEN
EOF
chmod 0755 "$STAGE/usr/lib/systemd/user-environment-generators/50-mesa-guest"

cat > "$STAGE/etc/profile.d/50-mesa-guest.sh" <<EOF
# Installed by ${pkg}. The flag is written at boot by mesa-guest-env.service iff a paravirt
# GPU is present; without it the variables stay unset and GL falls back to llvmpipe.
if [ -e /run/mesa-guest-gpu ]; then
    export MESA_LOADER_DRIVER_OVERRIDE=zink
    export VK_DRIVER_FILES=${icd}
    export VK_ICD_FILENAMES=${icd}
fi
EOF
chmod 0644 "$STAGE/etc/profile.d/50-mesa-guest.sh"

# ---------------------------------------------------------------------------
# The other way to hand a greeter a GLX with zero FBConfigs, and it is not an environment at all.
#
# A guest configured with BOTH `--simplefb` and `--gpu` has two DRM devices: simpledrm on the
# platform framebuffer and virtio-gpu on PCI. Xorg's autoconfiguration adds every DRM device it
# finds, the first as the screen and the rest as GPU screens, so modesetting loads glamor a second
# time for simpledrm -- where the only GL is llvmpipe. It says so ("Refusing to try glamor on
# llvmpipe", "glamor initialization failed") and carries on, but the server that comes up has no
# FBConfigs left: glxinfo reports "couldn't find RGB GLX visual or fbconfig" and zero configs,
# every GL client dies, and sddm loops its greeter forever on "Could not initialize GLX" with
# HelperExitStatus 6 -- the same signature as the GPU-less guest above, from the opposite cause,
# and with both screens black because nothing ever finishes a frame. Measured A/B on one boot:
# 0 FBConfigs with the GPU screen, 432 and direct rendering on zink/Turnip without it.
#
# simpledrm is never something to render on here. It is the boot framebuffer -- UEFI and early
# kernel write it, and after that the desktop belongs to virtio-gpu -- so the second device is
# not a GPU to offload to and Xorg must not treat it as one.
#
# Unconditional because it is a no-op in every configuration that is not this one: with only a
# virtio-gpu, or only a simplefb, there is no second device to add, and the sole device becomes
# the screen rather than a GPU screen either way. Nothing here can turn a working guest off.
install -d -m 0755 "$STAGE/etc/X11/xorg.conf.d"
cat > "$STAGE/etc/X11/xorg.conf.d/20-mesa-guest-no-autoaddgpu.conf" <<EOF
# Installed by ${pkg}. See the comment in mesa-cross/package.sh.
#
# With --simplefb and --gpu both configured the guest has two DRM devices, and Xorg would add
# simpledrm as a secondary GPU screen. glamor cannot initialize on it (llvmpipe), which leaves
# the server with zero GLX FBConfigs and crash-loops the display manager's greeter. simpledrm is
# the boot framebuffer, not a GPU to render on; the desktop belongs to virtio-gpu.
Section "ServerFlags"
    Option "AutoAddGPU" "off"
EndSection
EOF
chmod 0644 "$STAGE/etc/X11/xorg.conf.d/20-mesa-guest-no-autoaddgpu.conf"

root=$(mktemp -d)/deb
mkdir -p "$root"; cp -a "$STAGE/." "$root/"
install -d -m 0755 "$root/DEBIAN"
cat > "$root/DEBIAN/control" <<EOF
Package: ${pkg}
Version: ${PKGVER}
Section: libs
Priority: optional
Architecture: arm64
Installed-Size: $(du -sk "$root" | cut -f1)
Maintainer: Droid-VM <noreply@github.com>
Depends: libc6, libdrm2, libexpat1, libgcc-s1, libglvnd0, libllvm21, libstdc++6, libudev1, libvulkan1, libwayland-client0, libwayland-egl1, libwayland-server0, libx11-6, libx11-xcb1, libxcb1, libxcb-dri2-0, libxcb-dri3-0, libxcb-glx0, libxcb-present0, libxcb-randr0, libxcb-shm0, libxcb-sync1, libxcb-xfixes0, libxdamage1, libxext6, libxrandr2, libxshmfence1, libxxf86vm1, libzstd1, zlib1g
Conflicts: ${siblings}
Replaces: ${siblings}
Description: Guest Mesa for Droid-VM (gfxstream, venus and drm2kgsl)
 Mesa guest libraries carrying all three DroidVM Vulkan drivers -- gfxstream,
 venus (virtio) and freedreno over vdrm -- plus the Zink Gallium driver, an
 llvmpipe software fallback and the GLVND vendor libraries. The route is chosen
 at run time: mesa-guest-env.service probes at boot for a GPU the ICDs can
 drive; when one is present it applies the zink environment and VK_DRIVER_FILES
 names all three ICDs, with the loader keeping whichever one enumerates a
 device -- the one matching the virtio-gpu capset the VMM exposed. On a guest
 with no paravirt GPU (simplefb-only display) the environment is cleared
 instead and the desktop comes up on llvmpipe, software but alive. A guest with
 both a simplefb and a GPU gets an Xorg drop-in as well, keeping the server off
 the simpledrm device it would otherwise add as a GL-less GPU screen. Installs to
 /usr/local; the environment travels through a user-environment-generator,
 /etc/profile.d, a marked block in /etc/environment and systemctl
 set-environment, the last two being what reach a display manager: its greeter
 runs as a PAM session rather than a systemd user session, and the X server it
 starts is a system service that sees neither.
 .
 Supersedes the per-route mesa-guest-gfxstream, mesa-guest-venus, mesa-guest-drm2kgsl
 and mesa-guest-kgsl packages, which installed to the same prefix.
EOF
# The /etc/environment editing (markers, strip-every-block-first, rename-over-write) lives in
# mesa-guest-env now; postinst just runs it, so install-time and boot-time behavior cannot drift.
cat > "$root/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
ldconfig
[ "\$1" = configure ] || exit 0
if [ -d /run/systemd/system ]; then
    # Older versions delivered the override to system services through a static system.conf.d
    # DefaultEnvironment= drop-in. On upgrade dpkg has already deleted the file, but PID 1 still
    # holds what it said -- daemon-reexec is the only thing that drops it (daemon-reload does not
    # re-read system.conf). Also re-reads our unit file. Not fatal -- a reboot has the same
    # effect -- so never fail the install over it.
    systemctl daemon-reexec || echo "${pkg}: systemctl daemon-reexec failed; reboot to apply" >&2
fi
# The same probe-and-apply the boot service runs: installing is just "a boot happened now".
# A GPU-less guest gets its stale zink block stripped right here, not at next reboot.
/usr/lib/mesa-guest/mesa-guest-env
EOF
cat > "$root/DEBIAN/postrm" <<EOF
#!/bin/sh
set -e
ldconfig
case "\$1" in remove|purge) ;; *) exit 0 ;; esac
# mesa-guest-env is already deleted by the time postrm runs, so its cleanup half is inlined:
# strip the marked block, drop the boot flag, and clear the manager environment it set.
if [ -f /etc/environment ]; then
    sed '/^# BEGIN mesa-guest/,/^# END mesa-guest/d' /etc/environment \
        > /etc/environment.dpkg-new && mv -f /etc/environment.dpkg-new /etc/environment
fi
rm -f /run/mesa-guest-gpu
if [ -d /run/systemd/system ]; then
    systemctl unset-environment MESA_LOADER_DRIVER_OVERRIDE VK_DRIVER_FILES VK_ICD_FILENAMES 2>/dev/null || true
    # A guest that skipped straight from a static-drop-in version to removal still has PID 1
    # holding that DefaultEnvironment; reexec drops it. Harmless otherwise.
    systemctl daemon-reexec || true
fi
exit 0
EOF
chmod 0755 "$root/DEBIAN/postinst" "$root/DEBIAN/postrm"

deb="${pkg}_${PKGVER}_arm64.deb"
dpkg-deb --root-owner-group --build "$root" "$OUT/$deb"
echo "wrote $deb (ICDs: $icd)"
