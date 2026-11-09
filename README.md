# regulad/redroid-script: build branch

This branch builds [redroid](https://github.com/remote-android/redroid-doc)
images with Google apps for Android 12 through 16, standard and 64-bit-only,
for amd64 and arm64, and publishes them to `cr.regulad.xyz`. On amd64 they
also carry an ARM translation layer, so ARM-only apps run. The images are what
[Doppelganger](https://github.com/regulad/doppelganger) deploys, and they
work anywhere redroid does.

## Branches

- `ci` (this one, the default): the recipe and the pipeline.
- `main`: this fork's working branch. It holds the two 2024 changes, rebased
  onto upstream in December 2025, and an unfinished rewrite of the script
  (`rds`). The pipeline does not use it.
- `legacy/2024-07-22`: the exact script that built the images published on
  2024-07-22: upstream's `37e09b7`, then `541581e` and `cfe298a`. Those two
  commits fell off `main` when it was rebased, and are kept here. The pipeline
  reruns them to check that the reconstruction holds (see below).

Upstream is this fork's parent,
[ayasa520/redroid-script](https://github.com/ayasa520/redroid-script). Most
of what the recipe knows about each package's layout comes from it.

## Images

All are at `cr.regulad.xyz/regulad/redroid-script`, multi-architecture. Each
architecture is also tagged on its own, as `<android>-gapps-amd64-latest` and
`<android>-gapps-arm64-latest`.

| Tag | redroid base | arm64 | amd64 |
| --- | --- | --- | --- |
| `12.0.0-gapps-latest`, `12.0.0_64only-gapps-latest` | `12.0.0[_64only]-240527` | MindTheGapps 12.1 | MindTheGapps 12.1, redroid's libndk_translation |
| `13.0.0-gapps-latest`, `13.0.0_64only-gapps-latest` | `13.0.0[_64only]-240527` | MindTheGapps 13 | MindTheGapps 13, redroid's libndk_translation |
| `14.0.0-gapps-latest`, `14.0.0_64only-gapps-latest` | `14.0.0[_64only]-240527` | MindTheGapps 14 | LiteGapps 14 and its setup wizard, redroid's libndk_translation |
| `15.0.0-gapps-latest`, `15.0.0_64only-gapps-latest` | `15.0.0[_64only]-250627` | MindTheGapps 15 | LiteGapps 15 and its setup wizard, libhoudini |
| `16.0.0-gapps-latest`, `16.0.0_64only-gapps-latest` | `16.0.0[_64only]-250627` | MindTheGapps 16 | LiteGapps 15 and its setup wizard, libhoudini |

Where these came from:

- **MindTheGapps** is the official build from
  [MindTheGapps](https://github.com/MindTheGapps).
  Android 16's is the build of July 2025, a month after the redroid 16 base.
  The October 2026 build's Play services crashed on that base, looking for
  an Android 16 safety source (AdvancedProtection) it does not have.
- **LiteGapps** fills in amd64 14 to 16. MindTheGapps' own x86_64 builds stop
  at 13. [s1204IT/MindTheGappsBuilder](https://github.com/s1204IT/MindTheGappsBuilder)
  builds 14 and 15, but with the Play Store and Play services of 2022, which
  crash on them. LiteGapps' Android 16 build ships Play Store 45, which crash-
  loops on the redroid 16 base: Android refuses to run its "finish setting up"
  service. So amd64 16 takes LiteGapps' Android 15 build, whose Play Store
  (41.3) and Play services (24.23) are the ones amd64 14 and 15 run.
  LiteGapps leaves Google's setup wizard to an add-on, which the recipe adds
  (see below). The add-on's file name carries no date, so when LiteGapps
  replaces it, its pinned SHA-256 stops matching and the build fails until the
  pin is updated.
- **libndk_translation** comes with redroid's own amd64 12–14 bases.
- **libhoudini** is the build from Google Play Games for PC
  ([rote66/vendor_intel_proprietary_houdini](https://github.com/rote66/vendor_intel_proprietary_houdini)),
  with the linker-namespace fix from
  [rote66/redroid_libhoudini_hack](https://github.com/rote66/redroid_libhoudini_hack).

The tags move when a rebuild is published. To keep an image, pin its digest;
Doppelganger pins each device to the digest it was created from.

The `10.0.0-gapps-*` and `*-gapps-widevine-*` tags from 2024 are left as they
were and are not rebuilt.

## How it is built

- **Everything is pinned in [`matrix.json`](matrix.json).** Bases and tools by
  digest, downloads by SHA-256, git sources by commit. A change to any input is
  a commit here.
- **Almost nothing runs on the target architecture.** The
  [`Dockerfile`](Dockerfile) assembles the files on the build host and adds
  them to the base in one `COPY`. The one exception is a static busybox `rm`
  that takes out AOSP's Provision (see below); for arm64 it runs under the QEMU
  that BuildKit ships with, so the runner needs none of its own.
- **Builds are reproducible.** Timestamps come from `SOURCE_DATE_EPOCH`, the
  time of the last commit that changed an input, so the same inputs give the
  same layers. Pushing from BuildKit keeps the base's layers byte for byte as
  they are on Docker Hub.
- **Every image is booted before it's published.**
  [`scripts/smoke-test.sh`](scripts/smoke-test.sh) waits for Android to finish
  booting. It then checks:
  - Play services, Google Services Framework and the Play Store are installed
    as system apps.
  - None of them crashes while they start up, and system_server does not
    restart.
  - On amd64, the native bridge is set up and registered with binfmt_misc.
- **Images boot on ashmem, never memfd.** Android 16 only uses memfd if the
  kernel lets memfds answer ashmem's ioctls, which only Android's own kernels
  do; elsewhere it falls back to `/dev/ashmem`. So every version is tested the
  way it will run: on a kernel with ashmem.
- **The boot test runs in a VM** ([`scripts/vm.sh`](scripts/vm.sh)): Ubuntu
  22.04 on its 5.15 kernel, the newest Ubuntu kernel that ships `ashmem_linux`.
  Its disk is made once from a pinned cloud image ([`vm/`](vm/)) and cached.
  amd64 images boot under KVM. arm64 images are emulated by QEMU, because
  GitHub's Arm runners have no KVM, and emulating on x64 measured faster.
  Every job therefore runs on an x64 runner. Emulated, Android runs with
  `ro.hw_timeout_multiplier=5`, which Android provides for slow emulators: it
  stretches timeouts such as system_server's watchdog's.
- **One failure holds back only its own image.** An image is tagged only when
  both its architectures built and booted.
- **The tagged images are signed** with cosign, keyless, through GitHub's
  OIDC token.

Three corrections from upstream redroid-script are worth knowing:

- **AOSP's Provision is taken out**, as the MindTheGapps and LiteGapps
  installers do when they add Google's setup wizard. Android grants the setup
  wizard's own permissions only when exactly one app is the setup wizard. With
  both, Google's is refused them and crashes ("WifiService: Permission
  denied"), and it is the home screen until setup is done, so it keeps
  crashing. Every image carries Google's wizard, LiteGapps' through its
  add-on, so every image is set up the same way, and
  `ro.setupwizard.mode=DISABLED` in the entrypoint has it finish at once.

- **On amd64 15 and 16, libhoudini goes behind `libnb.so`.** Those redroid bases
  already set `ro.dalvik.vm.native.bridge=libnb.so` but ship no `libnb.so`.
- **The base's own `init.rc` is kept.** The houdini hack ships a whole `init.rc`
  per Android version, and its 15.0.0 one comes from an older redroid 15 build:
  it would undo 182 lines of the pinned base's. So the recipe adds only the
  hack's two lines to the base's own
  ([`native-bridge/patch-linkerconfig.awk`](native-bridge/patch-linkerconfig.awk)).

### Reproducing 2024

The `reproduce-2024` job checks out `legacy/2024-07-22` and runs
`redroid.py -a 12.0.0 -g -b`, as it was run on 2024-07-22, on an amd64 and an
arm64 runner. It then compares the result with the published 2024 image,
entry by entry:

- The base layer must be identical.
- The added layer must match in every file's content, mode and owner.
- The only difference allowed is when the script created `system/` and
  `system/priv-app/`.

On arm64 the script's scratch directory goes on XFS first. The script unpacks
whichever DPI variant of a package a directory listing returns first.
GmsCore's arm64 package has two variants: `nodpi`, which 2024 shipped, and
`480`. A filesystem that lists in creation order, as XFS does, returns `nodpi`
first; GitHub's ext4 returns `480`.

It confirms what the registry already suggested: the 2024 "Android 12" and
"Android 13" images carry Android 10's OpenGApps, the only package the script
downloaded. The `COPY gapps /` layer is the same in all three 2024 versions.

## Building locally

You need Docker with buildx, `jq` and `git`. Either architecture builds on
either kind of machine:

```sh
scripts/build.sh 16.0.0_64only amd64 --print   # the resolved inputs
scripts/build.sh 16.0.0_64only amd64 --load    # -> redroid-script:16.0.0_64only-amd64
```

To boot it, you need a kernel with binder and ashmem. On a host that has
them, such as Ubuntu 22.04 on its 5.15 kernel with `linux-modules-extra`:

```sh
scripts/smoke-test.sh redroid-script:16.0.0_64only-amd64 houdini 16.0.0_64only
```

Anywhere else, use the VM, as CI does. You need QEMU and `adb`:

```sh
scripts/vm.sh prepare amd64 vm-amd64.qcow2              # once
mkdir -p job && scripts/build.sh 16.0.0_64only amd64 --save job/image.tar
scripts/vm.sh start amd64 vm-amd64.qcow2 job
scripts/vm.sh ssh docker load -i /job/image.tar
SMOKE_REMOTE="scripts/vm.sh ssh" SMOKE_PUBLISH=0.0.0.0 \
  scripts/smoke-test.sh redroid-script:16.0.0_64only-amd64 houdini 16.0.0_64only
scripts/vm.sh stop
```

## Verifying a signature

```sh
cosign verify cr.regulad.xyz/regulad/redroid-script:16.0.0-gapps-latest \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/regulad/redroid-script/\.github/workflows/build\.yml@refs/heads/ci$'
```

## Licensing

The recipe on this branch (the Dockerfile, scripts, workflow and matrix) is
licensed under the GNU Affero General Public License, version 3: see
[LICENSE](LICENSE). The exception is
[`native-bridge/houdini.rc`](native-bridge/houdini.rc), taken from
redroid-script under the MIT license
([`native-bridge/LICENSE.redroid-script`](native-bridge/LICENSE.redroid-script)).

The images are not covered by that license. Each image combines software under
its own terms:

- redroid and AOSP, mostly under the Apache License 2.0.
- Google's apps, Google's libndk_translation and Intel's libhoudini, which are
  proprietary.

This repository downloads those at build time and redistributes none of them
in source form. It is not affiliated with Google, Intel, or the redroid,
MindTheGapps or LiteGapps projects.
