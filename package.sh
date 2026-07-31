#!/bin/bash
# Turn a staged `meson install` tree into a distro package.
#
#   package.sh <variant> <version> <deb|rpm> <stagedir> <outdir>
#
# Called by build-in-container.sh once the build is done. Both formats are produced from the SAME
# staged tree and the same environment files, so the only thing that differs between a guest's deb
# and its rpm is the metadata -- which is the point, because a route that behaves differently on
# one distro because its package was assembled differently is the hardest kind of difference to
# find.
#
# What has to be true on both, and why:
#
#   * The two variants share ~60 install paths (every kmsro *_dri.so, the gbm backend, libgallium)
#     and are therefore mutually exclusive. dpkg gets Conflicts+Replaces, which makes it REMOVE the
#     other; rpm gets Conflicts, which makes dnf refuse until you `dnf swap`. Neither may silently
#     overwrite: both ship libgallium, the desktop composites through gallium rather than through
#     the Vulkan ICD, and the overwrite is invisible until the whole screen is black.
#
#   * The environment is part of the package. MESA_LOADER_DRIVER_OVERRIDE=zink is not a tuning
#     knob -- both variants are built -Dgallium-drivers=zink, so without it GNOME Shell gets
#     "virtio_gpu: driver missing", falls back to kms_swrast and fails with "No GPUs found", while
#     Vulkan works the whole time and it looks like a gdm fault.
set -euo pipefail

# exec'd from build-in-container.sh, so the variant helpers have to be sourced again here.
source "${WORK_OUT:-/work/out}/mesa-variants.sh"

V=${1:?variant}
PKGVER=${2:?version}
FMT=${3:?deb|rpm}
STAGE=${4:?stagedir}
OUT=${5:?outdir}

pkg=$(mesa_variant_pkg "$V")
siblings=$(mesa_variant_siblings "$V")
icd=$(mesa_variant_icd "$V")

# ---------------------------------------------------------------------------
# Environment, identical in both formats.
#
# Two files because they cover different entry points, and neither is a conffile the admin owns:
# environment.d reaches systemd user sessions (the gdm greeter, GNOME, anything the session
# starts), profile.d reaches shell logins. Editing /etc/environment would cover both but is the
# admin's file, and a sed that rewrites it can drop a line it did not put there.
#
# VK_DRIVER_FILES is not strictly required -- the loader already searches /usr/local/share/vulkan
# -- but pinning it keeps the distro's software ICDs (lavapipe) out of the enumeration. An app
# quietly choosing llvmpipe is slow rather than broken, which is the hardest kind of regression to
# notice.
# ---------------------------------------------------------------------------
install -d -m 0755 "$STAGE/usr/lib/environment.d" "$STAGE/etc/profile.d"
cat > "$STAGE/usr/lib/environment.d/50-mesa-guest.conf" <<EOF
# Installed by ${pkg}. See /usr/share/doc/${pkg}.
MESA_LOADER_DRIVER_OVERRIDE=zink
VK_DRIVER_FILES=${icd}
VK_ICD_FILENAMES=${icd}
EOF
cat > "$STAGE/etc/profile.d/50-mesa-guest.sh" <<EOF
# Installed by ${pkg}.
export MESA_LOADER_DRIVER_OVERRIDE=zink
export VK_DRIVER_FILES=${icd}
export VK_ICD_FILENAMES=${icd}
EOF
chmod 0644 "$STAGE/usr/lib/environment.d/50-mesa-guest.conf" "$STAGE/etc/profile.d/50-mesa-guest.sh"

# The libdir is Debian's multiarch triplet on BOTH distros, because one meson configuration keeps
# the two builds comparable and every path this package pins (the ICD, the env files) is explicit
# anyway. Debian's ld.so already searches /usr/local/lib/aarch64-linux-gnu via
# /etc/ld.so.conf.d/aarch64-linux-gnu.conf; Fedora's searches only /lib and /lib64 (checked: its
# ld.so.conf.d is empty and ldconfig -v lists just those two builtins), so the rpm has to say so.
# Harmless on Debian, so it ships in both rather than being a per-format difference.
install -d -m 0755 "$STAGE/etc/ld.so.conf.d"
cat > "$STAGE/etc/ld.so.conf.d/50-mesa-guest.conf" <<'EOF'
# Installed by mesa-guest-*: this prefix is not in Fedora's default search path.
/usr/local/lib/aarch64-linux-gnu
EOF
chmod 0644 "$STAGE/etc/ld.so.conf.d/50-mesa-guest.conf"

case "$FMT" in
# ---------------------------------------------------------------------------
deb)
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
Depends: libc6, libdrm2, libexpat1, libgcc-s1, libglvnd0, libstdc++6, libudev1, libvulkan1, libwayland-client0, libwayland-egl1, libwayland-server0, libx11-6, libx11-xcb1, libxcb1, libxcb-dri2-0, libxcb-dri3-0, libxcb-glx0, libxcb-present0, libxcb-randr0, libxcb-shm0, libxcb-sync1, libxcb-xfixes0, libxdamage1, libxext6, libxrandr2, libxshmfence1, libxxf86vm1, libzstd1, zlib1g
Provides: mesa-guest
Conflicts: mesa-guest, ${siblings}
Replaces: mesa-guest, ${siblings}
Description: Guest Mesa for Droid-VM (${V} route)
 Mesa guest libraries with the ${V} Vulkan driver, the Zink Gallium driver and
 the GLVND vendor libraries. Installs to /usr/local, and ships the environment it
 needs (MESA_LOADER_DRIVER_OVERRIDE, VK_DRIVER_FILES) in /usr/lib/environment.d
 and /etc/profile.d, so a desktop comes up without any manual setup.
 .
 Only one mesa-guest-* package can be installed at a time: they share a prefix.
EOF
    printf '#!/bin/sh\nset -e\nldconfig\n' > "$root/DEBIAN/postinst"
    printf '#!/bin/sh\nset -e\nldconfig\n' > "$root/DEBIAN/postrm"
    chmod 0755 "$root/DEBIAN/postinst" "$root/DEBIAN/postrm"

    deb="${pkg}_${PKGVER}_arm64.deb"
    dpkg-deb --root-owner-group --build "$root" "$OUT/$deb"
    echo "wrote $deb (variant $V, ICD $icd)"
    ;;

# ---------------------------------------------------------------------------
rpm)
    # rpm forbids '-' in Version. mesa's VERSION carries it on development branches
    # ("26.3.0-devel"), and '~' is the right replacement rather than '.': it sorts BELOW the
    # release, so 26.3.0~devel < 26.3.0, which is what a devel snapshot means.
    rpmver=${PKGVER//-/\~}
    top=$(mktemp -d)
    mkdir -p "$top"/{SPECS,SOURCES,BUILD,RPMS,SRPMS,BUILDROOT}
    cp -a "$STAGE" "$top/SOURCES/payload"

    # Conflicts on the sibling NAMES rather than on file paths: rpm would otherwise report the
    # collision as ~60 individual "file ... conflicts between attempted installs", which buries
    # the one fact that matters (these are alternatives, pick one).
    #
    # Only the siblings. The deb idiom of Provides+Conflicts on a shared virtual name does NOT
    # carry over: dpkg exempts a package from its own Provides, rpm does not, so
    # "Provides: mesa-guest" plus "Conflicts: mesa-guest" is a package that conflicts with itself.
    rpm_conflicts=$(echo "$siblings" | tr ',' '\n' | sed 's/^/Conflicts:      /')

    # Every soname this package itself ships, as a regex alternation.
    #
    # Needed because Provides is suppressed for /usr/local (below): without that suppression we
    # would advertise libEGL_mesa.so.0 system-wide and become a candidate to satisfy someone
    # else's dependency, but WITH it, our libraries' internal references to each other are
    # generated as unsatisfiable external Requires -- and dnf resolves them by pulling in
    # Fedora's own mesa, whose libEGL_mesa then sits in /usr/lib64 competing with ours.
    #
    # So: drop exactly the dependencies we satisfy ourselves, and keep every genuine external one
    # (libc, libdrm, libwayland, ...) so a Fedora missing them fails at install rather than at
    # runtime. Derived from the tree, so it cannot drift from what is actually shipped.
    #
    # Backslashes are DOUBLED because a %global body is macro-expanded and eats one level of
    # them. With a single level, "\." arrives as "." (harmless: matches any character) but the
    # trailing "\(" arrives as "(", which leaves the alternation's parentheses unbalanced -- and
    # rpm answers an invalid regex by silently not filtering anything. The symptom is a package
    # that still Requires the very sonames it ships, with a correct-looking regex in the spec.
    own=$( (cd "$STAGE" && find . \( -type f -o -type l \) -name '*.so*' -printf '%f\n') \
           | sed 's/\./\\\\./g' | sort -u | paste -sd'|' )

    # Explicit file list rather than "%files /usr/local". /usr, /usr/local, /usr/local/lib,
    # /etc/profile.d and friends belong to the `filesystem` package; claiming them makes this
    # package fight the base system over directory ownership, and removing it would try to take
    # them with it. So: own every file, and own only the directories we actually created.
    filelist=$top/SOURCES/filelist
    ( cd "$STAGE"
      find . \( -type f -o -type l \) -printf '/%P\n'
      find . -type d -printf '/%P\n' | while read -r d; do
          case "$d" in
          /|/usr|/usr/lib|/usr/lib/environment.d|/usr/local|/usr/local/lib|/usr/local/bin \
          |/usr/local/share|/usr/local/include|/usr/local/etc|/etc|/etc/profile.d|/etc/ld.so.conf.d) ;;
          *) echo "%dir $d" ;;
          esac
      done
    ) | sort -u > "$filelist"

    cat > "$top/SPECS/$pkg.spec" <<EOF
%global debug_package %{nil}
# Nothing here is built by rpm, so the buildroot policy scripts have nothing correct to do:
# stripping would rewrite binaries the deb ships unstripped, which is exactly the kind of
# difference that makes one distro behave unlike the other for no stated reason.
%global __brp_strip %{nil}
%global __brp_strip_static_archive %{nil}
%global __brp_strip_comment_note %{nil}
# Take dependencies from the ELF files (rpm reads their DT_NEEDED and version symbols, which is
# more accurate than any hand-written list), but publish NO provides: these libraries have the
# same sonames as Fedora's own mesa, and advertising libEGL_mesa.so.0 from /usr/local would make
# this package a candidate to satisfy something else's dependency.
%global __provides_exclude_from ^/usr/local/.*\$
%global __requires_exclude ^(${own})\\\\(

Name:           ${pkg}
Version:        ${rpmver}
Release:        1
Summary:        Guest Mesa for Droid-VM (${V} route)
License:        MIT
URL:            https://github.com/Droid-VM/mesa

Provides:       mesa-guest
${rpm_conflicts}

%description
Mesa guest libraries with the ${V} Vulkan driver, the Zink Gallium driver and
the GLVND vendor libraries. Installs to /usr/local, and ships the environment it
needs (MESA_LOADER_DRIVER_OVERRIDE, VK_DRIVER_FILES) in /usr/lib/environment.d
and /etc/profile.d, so a desktop comes up without any manual setup.

Only one mesa-guest-* package can be installed at a time: they share a prefix.
To change route: dnf swap ${siblings%%,*} ${pkg}

%prep
%build

%install
cp -a %{_sourcedir}/payload/. %{buildroot}/

%files -f ${filelist}

%post
/sbin/ldconfig

%postun
/sbin/ldconfig

%changelog
* $(LC_ALL=C date -u '+%a %b %d %Y') Droid-VM <noreply@github.com> - ${rpmver}-1
- Built from mesa ${PKGVER}, variant ${V}
EOF

    # --target aarch64 is a no-op on the Fedora aarch64 builder where this normally runs, and is
    # what lets the packaging step be exercised on its own from an x86_64 container: nothing is
    # compiled here, and rpm reads the aarch64 ELFs for dependencies regardless of host arch.
    rpmbuild --define "_topdir $top" --target aarch64 -bb "$top/SPECS/$pkg.spec" >/dev/null
    rpm=$(find "$top/RPMS" -name '*.rpm' | head -n1)
    [ -n "$rpm" ] || { echo "error: rpmbuild produced no rpm" >&2; exit 1; }
    cp "$rpm" "$OUT/"
    echo "wrote $(basename "$rpm") (variant $V, ICD $icd)"
    ;;

*) echo "error: unknown package format '$FMT'" >&2; exit 2 ;;
esac
