# Handoff — tachyon-composer new-BP migration

Date: 2026-06-20 · Branch: `feature/new-bp` · Author handoff for the US team to continue.

This document is the practical handoff. For the design rationale see
[`docs/plans/2026-06-19-composer-new-bp-migration-design.md`](docs/plans/2026-06-19-composer-new-bp-migration-design.md);
for the build steps see [`BUILDING.md`](BUILDING.md); for dev conventions see [`AGENTS.md`](AGENTS.md).

---

## 1. TL;DR

tachyon-composer has been migrated from the legacy **20.04→24.04 upgrade** tool (U-Boot /
`xbl.elf` / `qtestsign` / `rawprogram` editing) to the **new BP** backend: QCM6490 / Quectel
bp-fw r108 (2.0.0), **UEFI boot chain**, partitions assembled with `ptool` + `partition_ext`
(`system` / `efi` / `dtb_a` / `core_nhlos_a` + `QCM6490_bootbinaries`).

- The rootfs front-end is **unchanged**: 24.04 base image + `tachyon-overlay-tool` stack.
- The boot/assembly back-end is **replaced** with the one already validated on hardware in
  `tachyon-eugene` (vendored into `assemble/`, `build-efi/`, `build-dtb/`, `build-nonhlos/`).
- The command and main target users know are **kept**: `make build_24.04` and `compose_24_04.sh`.

Build command (RoW / headless):

```bash
make build_24.04 VERSIONS_FILE=./versions.json INPUT_REGION=RoW INPUT_VARIANT=headless
# in CI add CI=true so docker runs without -it
```

A full image was built locally and produced a flashable EDL zip (4.3 GB) — see §6.

---

## 2. The two non-obvious gotchas: kernel install + build environment

Read this before touching `versions.json` or running a local x86 build.

### 2a. Kernel: the rootfs ends up with TWO kernels

- The **rootfs kernel** is baked into the 24.04 **base image** by livecd-rootfs (it installs the
  latest `linux-particle` from `packages.particle.io/ubuntu noble-stable` at *base*-build time,
  no pin). Both `image-21-4d6898e` and `image-22-938ac1d` ship the **1056** line — confirmed by
  the build log: `Unpacking linux-particle (…1058.59+particle2) over (…1056.57+particle6)`.
  (My earlier guess that image-22 was the 1058 line was **wrong** — it is 1056particle6.)
- We want a fully **particle2** image. The `check-pinned-packages` overlay runs
  `apt install linux-particle=6.8.0-1058.59+particle2 …`. Because `linux-image-6.8.0-1058-particle`
  is a **different package name** from the base's `…-1056-particle`, apt **adds the whole 1058
  kernel as a fresh install, alongside the base's 1056 kernel** — there is **no "can't cross ABI"
  problem**. So particle2 installs fine on a 1056 base.
- `versions.json` is set to:
  - `sources["particle-iot/tachyon-ubuntu-24.04"].param = "22-938ac1d"` (a newer base commit than
    the original image-21; the choice does **not** depend on its kernel line — both are 1056)
  - `env.PKG_linux_particle = "6.8.0-1058.59+particle2"`
- `dtb_a` is `qcm6490-tachyon.dtb` from the particle2 kernel deb (independent of the base). →
  the installed/pinned kernel **and** the dtb are both particle2.

> **Consequences to be aware of** (candidates for cleanup in the overlay stack, not composer):
> - The rootfs has **both** the 1056 (base) and 1058 (pinned) kernels installed. `dtb_a` is the
>   1058 dtb, so boot must select the 1058 kernel — **verify on hardware**, and consider removing
>   the unused 1056 kernel in the overlay stack.
> - If you ever need a different kernel baked into the base itself, the base repo
>   `particle-iot/tachyon-ubuntu-24.04` auto-builds + releases a new `image-N` on **any push to
>   main** (CircleCI; no cron — only when something is pushed); a fresh build picks up the
>   then-latest noble-stable kernel.

### 2b. Disk space + (x86 host only) qemu version

- **Disk space.** Installing the full 1058 kernel (modules + headers) on top of the base's 1056
  kernel, plus the pinned Particle packages, the overlay stack's apps and their deps, needs more
  room than the default rootfs headroom. **+3GB overflowed** (`No space left on device`); it is
  now **+6GB** in `compose_24_04.sh` step 1 (the `system` partition is 10GB, so an ~8.4GB rootfs
  fits).
- **qemu (x86_64 build hosts only).** The overlay runs an arm64 chroot via qemu-user-static. The
  `ubuntu-common-24.04` stack installs `mpv`, which pulls `python3-mutagen`; its postinst
  (py3compile) **segfaults (exit 139) under Ubuntu's qemu 8.2.2**. Fix: use a newer qemu — qemu
  **10.2.3** (from `tonistiigi/binfmt`) builds cleanly. Register it once:
  ```bash
  docker run --privileged --rm tonistiigi/binfmt:latest --uninstall qemu-aarch64
  docker run --privileged --rm tonistiigi/binfmt:latest --install arm64
  ```
  This is **only** a local x86 issue. The self-hosted `ubuntu-tachyon` CI runner is real arm64
  (no qemu), so it is unaffected.

### 2c. Flashing needs manifest.json

`particle flash --tachyon <zip>` requires a top-level `manifest.json` (its `targets.edl` names the
firehose + program/patch XMLs). The legacy composer inherited it from the 20.04 base; the new-BP
`make_factory_img.sh` does not, so `compose_24_04.sh` now synthesizes it after assembly (base `.`,
`prog_firehose_ddr.elf`, rawprogram0-5, patch0-5). Without it, `particle flash` fails immediately
with `Unable to find manifest.json`.

---

## 3. Component sourcing

| Partition / component | Source |
|---|---|
| `system` (rootfs.ext4) | composer: 24.04 base `image-22-938ac1d` + overlay stack `ubuntu-<variant>-24.04` |
| `efi` (efi.img) | vendored GRUB ESP in `build-efi/` |
| `dtb_a` (dtb.img) | `qcm6490-tachyon.dtb` extracted from the kernel deb (`build-dtb/`) |
| `core_nhlos_a` (nonhlos-<region>.img) | vendored per-region firmware blobs `build-nonhlos/{em,na}/` |
| bootbinaries / fw | S3 permanent release `tachyon-ci.particle.io/release/tachyon-bp-fw-2.0.0.zip` |
| kernel deb | S3 permanent release `linux-dist.particle.io/kernel/release/stable-6.8.0-1058.59particle2/` |
| ptool / partition_ext / cdt.bin | vendored from eugene in `assemble/` |

> Note on `dtb_a`: the file inside is named `combined-dtb.dtb` only because that is the fixed name
> EDK2/UEFI reads from the partition. Its contents are the single-board `qcm6490-tachyon.dtb`
> (added to the kernel deb by particle-iot/tachyon-ubuntu-24.04-kernel PR #29, in particle2+). Do
> **not** use the kernel Makefile's multi-board `combined-dtb.dtb`.

---

## 4. File changes (branch `feature/new-bp`)

**Rewritten:**
- `Makefile` — new-BP orchestration: `fetch_24_04 / fetch_bp_fw / fetch_kernel_deb /
  fetch_overlay_tool / fetch_tachyon_overlays → compose_24_04.sh`. Reads `versions.json`.
- `compose_24_04.sh` — rootfs (+6GB headroom) → efi → overlay (`run-overlay.sh -f`) → dtb →
  nonhlos → assemble → **manifest.json** → zip.
- `versions.json` — new-BP sources + env pins (see §2).

**Vendored (new backend, from eugene):**
- `assemble/` (ptool.py, cdt.bin, config/partition_ext.xml, config/provision_ufs22.xml, make_factory_img.sh)
- `build-efi/`, `build-dtb/`, `build-nonhlos/` (renamed from `efi/`, `dtb/`, `nonhlos/`)

**Edited:**
- `Dockerfile` — added `mtools`; bumped `# particle-dockerfile-version` to `1.4`.
- `build-nonhlos/make-nonhlos_img.sh` — FAT16 (`mkfs.vfat -F 16 -S 4096`) + `mdir` sanity check.
- `build-dtb/build-dtb.sh` — self-contained extractor for `qcm6490-tachyon.dtb`.
- `README.md`, `AGENTS.md`, `BUILDING.md` — updated to the new backend; all docs are English.

**Deleted (legacy upgrade path):**
- `prepare_base_24.04.sh`, `xml_tools.py`.

---

## 5. Build, flash, verify

```bash
# x86_64 host: register newer qemu once (see §2b)
# build (downloads ~1GB base on first run; later runs reuse ./.tmp/input)
make build_24.04 VERSIONS_FILE=./versions.json INPUT_REGION=RoW INPUT_VARIANT=headless
# output: ./.tmp/output/tachyon-ubuntu-24.04-RoW-headless-formfactor_dvt-9.9.999.zip

# flash
tachyon.sh edl
particle flash --tachyon ./.tmp/output/<the>.zip
```

A common failure and its cause are documented in `BUILDING.md` §9 (`check-pinned-packages`,
disk space, qemu).

---

## 6. Verification status — PASS (build + flash + boot)

- **Build (image-22 + particle2): PASS.** `make build_24.04 … RoW … headless` ran end to end with
  qemu 10.2.3 → `tachyon-ubuntu-24.04-RoW-headless-formfactor_dvt-9.9.999.zip` (4.3 GB).
- **Flash via `particle flash --tachyon`: PASS.** With `manifest.json` emitted (§2c),
  `particle flash --tachyon <zip>` → `OS Download complete` (qdl: `prog_firehose_ddr.elf` +
  rawprogram0-5 + patch0-5).
- **Boot: PASS.** Device booted to `ubuntu login:`; logged in (root/particle):
  `uname -r = 6.8.0-1058-particle` (`#59+particle2`), `Ubuntu 24.04.4 LTS`. `/lib/modules` has
  both 1056 and 1058 kernels; boot correctly selected **1058** (matches dtb_a).

---

## 7. Known issues / next steps

1. ~~Flash + boot the particle2 zip on hardware~~ — **DONE** (see §6): boots to `ubuntu login:`,
   runs `6.8.0-1058-particle #59+particle2`, boot selected the 1058 kernel (matches dtb_a).
2. **Headless image is bloated (4.3 GB).** The `ubuntu-common-24.04` overlay stack installs
   desktop/media apps (`cheese`, `nautilus`, `mpv` + a large GNOME dep tree) for **both** headless
   and desktop, and the rootfs carries **two** kernels (1056 + 1058). Worth trimming in the
   overlay repo (this is a `tachyon-overlays` design question, not a composer bug):
   the camera/media apps and the unused 1056 kernel.
3. **rootfs boot adaptation** — composer's rootfs was designed for U-Boot; under UEFI/new-BP it
   may need kernel cmdline / fstab / mount-point tweaks. The overlay stack is the place to add new
   mounts / msm blacklist (see eugene's `tachyon-console` stack).
4. **Matrix coverage** — only RoW/headless built locally. Extend to NA (`INPUT_REGION=NA` →
   nonhlos `na`) and desktop (`INPUT_VARIANT=desktop`).
5. **CI** — `.github/workflows` still reflect legacy-flow assumptions in places; wire the
   self-hosted (real arm64, no qemu) runner build to the new targets with `CI=true`.
6. **Cleanup opportunity** — once the rootfs kernel story is settled, the separate
   `fetch_kernel_deb` could be dropped by extracting `qcm6490-tachyon.dtb` directly from the
   overlaid rootfs instead of a standalone deb. Kept explicit for now.
