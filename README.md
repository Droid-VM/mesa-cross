# mesa-cross

The build recipe for DroidVM's **guest** mesa: cross-compiles
[Droid-VM/mesa](https://github.com/Droid-VM/mesa) for aarch64 on an x86_64
host and packages it as one `.deb` per graphics route.

| variant | mesa branch | Vulkan driver | package |
|---|---|---|---|
| `gfxstream` | `<family>-gfxstream` (26.0.3) | gfxstream guest ICD | `mesa-guest-gfxstream_<ver>_arm64.deb` |
| `drm2kgsl` | `<family>-drm2kgsl` (26.3.0-devel) | turnip over vdrm (freedreno, kmds `msm,virtio`) | `mesa-guest-drm2kgsl_<ver>_arm64.deb` |
| `venus` | `<family>-venus` (26.0.3) | venus (`vn`) | `mesa-guest-venus_<ver>_arm64.deb` |

`<family>` is the branch line, `wip/3d-accel` today. All three build zink +
GLVND on top, install to `/usr/local`, and **Conflict** with each other: a
guest holds one route at a time and `apt install ./mesa-guest-<v>_*.deb` swaps
them. `mesa-variants.sh` is the single place where the per-variant meson
options, package names, ICD paths and the version scheme are written down;
everything else reads it.

## How it builds

Native x86 compiler emitting aarch64 against Ubuntu 26.04 (resolute) multiarch
`:arm64` -dev packages — no qemu, no sysroot, minutes rather than hours. The
environment is `Dockerfile.mesa-cross`; the cross file is
`aarch64-linux-gnu.meson`; `build-in-container.sh` configures/builds/stages and
`package.sh` turns the staged tree into a `.deb` (including the environment the
desktop needs: `MESA_LOADER_DRIVER_OVERRIDE=zink` + the ICD path, delivered
through environment.d, profile.d, `/etc/environment` and systemd
`system.conf.d` — the comments in `package.sh` explain why each one exists).

```
build.sh <variant> <mesa-checkout> <package-version> <outdir>
```

`build.sh` knows nothing about git: it is handed a path. Two callers do the
git-shaped work:

* **the meta repo** [droidvm-3d-accel](https://github.com/Droid-VM/droidvm-3d-accel):
  `1_build_crosvm_prepare.sh` clones this repo next to everything else,
  `8_build_guest_mesa_{gfx,drm2kgsl,venus}.sh` resolve the mesa branch from the
  meta repo's own branch, keep the three variants as worktrees of one clone,
  and call `build.sh`. Output lands in `dist-guest/`.
* **CI** — `ci-build.sh <variant> [family] [outdir]` clones the one mesa branch it
  needs (single-branch, `--filter=blob:none`, so the commit count in the version
  is right without a full clone) and calls `build.sh`. This is what the GitHub
  Actions workflow runs; it works the same on a workstation with docker + git:

  ```
  ./ci-build.sh venus wip/3d-accel        # -> out/mesa-guest-venus_<ver>_arm64.deb + out/venus.env
  ```

## GitHub Actions

**Actions → guest mesa → Run workflow.** Manual only (`workflow_dispatch`).

Two branch choices, and they are independent:

* *Use workflow from* — which **mesa-cross** ref provides the recipe (this
  workflow, `build.sh`, `mesa-variants.sh`). Any branch or tag of this repo.
* `branch` — which **mesa branch family** to build: `Droid-VM/mesa`
  `<family>-<variant>`. Left empty it follows the ref above, the same rule the
  meta repo applies to its own branch.

Inputs:

* `branch`: the family, e.g. `wip/3d-accel` or `pr/3d-accel`.
* `variants`: subset, space separated. Default all three.
* `mesa_repo`: build a fork instead (`owner/name`).
* `release` / `tag` / `prerelease`: publish the `.deb`s + `MD5SUMS` as a
  release. Default tag `mesa-guest-<family>-<run number>`; giving an existing
  tag updates that release in place. The release notes record the exact mesa
  commit each package came from.
* `refresh_env`: rebuild the cross environment image without the layer cache
  (the arm64 -dev packages are otherwise frozen in the cache until the
  Dockerfile or `ubuntu.sources` changes).

The variants build in parallel; a release is only created when every requested
variant succeeded, and the `.deb`s of a partial run remain available as workflow
artifacts.

### A second line of work

Nothing needs adding here for a new branch family. Say the work moves to
`pr/3d-accel`, with mesa branches `pr/3d-accel-{gfxstream,drm2kgsl,venus}` —
either way works:

* **Type the family.** Stay on mesa-cross `wip/3d-accel` and put `pr/3d-accel`
  in the `branch` box. One click, and the recipe is the one the trunk uses.
* **Branch mesa-cross too.** `git switch -c pr/3d-accel` here, push, and select
  it in *Use workflow from* with `branch` left empty. Use this when the recipe
  itself has to differ for that line (a new meson option, a fourth variant):
  the workflow file that runs is the one on the selected branch.

`workflow_dispatch` needs the workflow present on the **default branch** to be
dispatchable at all, so keep it there (`wip/3d-accel` today) when you add
branches.

From the CLI, the same thing:

```
gh workflow run build-guest-mesa.yml -R Droid-VM/mesa-cross \
  --ref wip/3d-accel \
  -f branch=pr/3d-accel -f variants='venus' -f release=false
```

Before any container starts, the run checks that every requested
`<family>-<variant>` exists on the mesa remote, and fails in seconds with the
list of branches that family *does* have — a new line usually has only one or
two of the three pushed, and that is the moment to find out.

## Versioning

`<mesa VERSION>+droidvm.r<commit count>.g<short sha>[+dirty<timestamp>]`, e.g.
`26.0.3+droidvm.r217841.ge14d2e5f`. The commit count leads so that apt can order
builds of the same branch (a hash does not sort); see `mesa_pkg_version` in
`mesa-variants.sh` for why the `r` matters too.

## Licensing

Written for DroidVM: GNU GPL v3 or later **with the additional permissions in
`ADDITIONAL-PERMISSIONS`** (they let this material be relicensed for the sole
purpose of taking it upstream). Sign-off is required for contributions; see
`CONTRIBUTING.md`. mesa itself stays under its own (MIT) license — this repo
only builds it.
