# mesa-cross

The build recipe for DroidVM's **guest** mesa: cross-compiles
[Droid-VM/mesa](https://github.com/Droid-VM/mesa) for aarch64 on an x86_64
host and packages it as one `.deb` carrying all three graphics routes.

| route | Vulkan driver | ICD |
|---|---|---|
| `gfxstream` | gfxstream guest ICD, paired with the host gfxstream decoder | `gfxstream_vk_icd.aarch64.json` |
| `venus` | venus (`vn`), speaking the venus wire to virglrenderer's vkr | `virtio_icd.aarch64.json` |
| `drm2kgsl` | turnip over vdrm (freedreno, kmds `msm,virtio`) | `freedreno_icd.aarch64.json` |

One branch, one build, one package: `mesa-guest_<ver>_arm64.deb`. Until
2026-08-18 this was three packages from three mesa branches, because the routes
sat on unrelated upstream lines — gfxstream and venus on 26.0.3, drm2kgsl on
26.3.0-devel. Once every route was rebased onto the same upstream commit the
three trees turned out to touch disjoint files (`src/gfxstream/**`,
`src/virtio/vulkan/vn_*`, `src/freedreno/**`), so they collapsed into one.

**The route is chosen at run time, not install time.** `VK_DRIVER_FILES` names
all three ICDs and the Vulkan loader keeps whichever one enumerates a device: a
DroidVM guest sees exactly one virtio-gpu capset, so exactly one answers. That
is why the package no longer Conflicts with a sibling — but it does supersede
the old per-route `mesa-guest-{gfxstream,venus,drm2kgsl,kgsl}` packages, which
installed to the same paths, so installing it removes them.

`mesa-config.sh` is the single place where the meson options, the package name,
the ICD list and the version scheme are written down; everything else reads it.

## How it builds

Native x86 compiler emitting aarch64 against Ubuntu 26.04 (resolute) multiarch
`:arm64` -dev packages — no qemu, no sysroot, minutes rather than hours. The
environment is `Dockerfile.mesa-cross`; the cross file is
`aarch64-linux-gnu.meson`; `build-in-container.sh` configures/builds/stages and
`package.sh` turns the staged tree into a `.deb` (including the environment the
desktop needs: `MESA_LOADER_DRIVER_OVERRIDE=zink` + the ICD list, delivered
through environment.d, profile.d, `/etc/environment` and systemd
`system.conf.d` — the comments in `package.sh` explain why each one exists).

```
build.sh <mesa-checkout> <package-version> <outdir>
```

`build.sh` knows nothing about git: it is handed a path. Two callers do the
git-shaped work:

* **the meta repo** [droidvm-3d-accel](https://github.com/Droid-VM/droidvm-3d-accel):
  `1_build_crosvm_prepare.sh` clones this repo next to everything else,
  `8_build_guest_mesa.sh` resolves the mesa branch from the meta repo's own
  branch and calls `build.sh`. Output lands in `dist-guest/`.
* **CI** — `ci-build.sh [branch] [outdir]` clones the mesa branch it needs
  (single-branch, `--filter=blob:none`, so the commit count in the version is
  right without a full clone) and calls `build.sh`. This is what the GitHub
  Actions workflow runs; it works the same on a workstation with docker + git:

  ```
  ./ci-build.sh wip/3d-accel        # -> out/mesa-guest_<ver>_arm64.deb + out/build.env
  ```

## GitHub Actions

**Actions → guest mesa → Run workflow.** Manual only (`workflow_dispatch`).

Two branch choices, and they are independent:

* *Use workflow from* — which **mesa-cross** ref provides the recipe (this
  workflow, `build.sh`, `mesa-config.sh`). Any branch or tag of this repo.
* `branch` — which **Droid-VM/mesa** branch to build. Left empty it follows the
  ref above, the same rule the meta repo applies to its own branch.

Inputs:

* `branch`: the mesa branch, e.g. `wip/3d-accel` or `pr/3d-accel`.
* `mesa_repo`: build a fork instead (`owner/name`).
* `release` / `tag` / `prerelease`: publish the `.deb` + `MD5SUMS` as a
  release. **The default tag is the branch name with `/` replaced by `_`** —
  git will not accept a tag containing `/` while a branch of the same name
  exists — so a branch has exactly one release and re-running the workflow
  updates it in place rather than accumulating one release per run. Marked as a
  **pre-release** by default. The notes record the exact mesa commit the package
  came from.
* `refresh_env`: rebuild the cross environment image without the layer cache
  (the arm64 -dev packages are otherwise frozen in the cache until the
  Dockerfile or `ubuntu.sources` changes).

### A second line of work

Nothing needs adding here for a new branch. Say the work moves to
`pr/3d-accel` — either way works:

* **Type the branch.** Stay on mesa-cross `wip/3d-accel` and put `pr/3d-accel`
  in the `branch` box. One click, and the recipe is the one the trunk uses.
* **Branch mesa-cross too.** `git switch -c pr/3d-accel` here, push, and select
  it in *Use workflow from* with `branch` left empty. Use this when the recipe
  itself has to differ for that line (a new meson option, a fourth driver): the
  workflow file that runs is the one on the selected branch.

`workflow_dispatch` needs the workflow present on the **default branch** to be
dispatchable at all, so keep it there (`wip/3d-accel` today) when you add
branches.

From the CLI, the same thing:

```
gh workflow run build-guest-mesa.yml -R Droid-VM/mesa-cross \
  --ref wip/3d-accel \
  -f branch=pr/3d-accel -f release=false
```

Before any container starts, the run checks that the requested branch exists on
the mesa remote, and fails in seconds with the list of branches that do — not
twenty minutes into a container build.

## Versioning

`<mesa VERSION>+droidvm.r<commit count>.g<short sha>[+dirty<timestamp>]`, e.g.
`26.3.0-devel+droidvm.r227723.g94563500`. The commit count leads so that apt can
order builds of the same branch (a hash does not sort); see `mesa_pkg_version`
in `mesa-config.sh` for why the `r` matters too.

## Licensing

Written for DroidVM: GNU GPL v2 or later **with the additional permissions in
`ADDITIONAL-PERMISSIONS`** (they let this material be relicensed for the sole
purpose of taking it upstream). Sign-off is required for contributions; see
`CONTRIBUTING.md`. mesa itself stays under its own (MIT) license — this repo
only builds it.
