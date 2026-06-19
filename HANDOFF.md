# Handoff — tachyon-composer new-BP migration

Date: 2026-06-19 · Branch: `feature/new-bp` · Author handoff for the US team to continue.

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

---

## 2. The one non-obvious thing: kernel / base version

This is the part most likely to bite you, so read it.

- The **rootfs kernel** is baked into the 24.04 **base image** by livecd-rootfs, which installs
  the latest `linux-particle` from `packages.particle.io/ubuntu noble-stable` at *base*-build
  time. The composer overlay can only `apt upgrade` the kernel **within the same ABI** — it
  cannot cross ABIs (e.g. 1056 → 1058). The `check-pinned-packages` overlay **fails** if the
  pinned `PKG_linux_particle` cannot be installed on the base's kernel line.
- We want a fully **particle2** image. We get it **without rebuilding the base** by choosing base
  **`image-22-938ac1d`** (built 2026-01-07, after the 1058 line shipped), whose rootfs kernel is
  the **1058** line. `versions.json` is set to:
  - `sources["particle-iot/tachyon-ubuntu-24.04"].param = "22-938ac1d"`
  - `env.PKG_linux_particle = "6.8.0-1058.59+particle2"`
- The overlay then patch-upgrades `linux-image-6.8.0-1058-particle` 1058particle1 → 1058particle2
  (same ABI → installable), `check-pinned-packages` passes, and `dtb_a` is `qcm6490-tachyon.dtb`
  from the particle2 kernel deb (independent of the base). → rootfs kernel **and** dtb are both
  particle2.

Evidence (so you can re-derive it):

| base | built | latest `linux-particle` then | kernel line |
|---|---|---|---|
| `image-21-4d6898e` (old) | 2025-12-04 | 1056particle5 (1058 line not out yet) | **1056** |
| `image-22-938ac1d` (now) | 2026-01-07 | **1058particle1** (1058 line shipped 2025-12-30) | **1058** |

`noble-stable` keeps all versions of the `linux-particle` meta (1056particle3–6, 1058particle1–2);
the base build has no kernel pin, so it installs the **highest** version available on its build
day, and `1058.59 > 1056.57`.

> If you ever need a different kernel line in the rootfs, the base repo
> `particle-iot/tachyon-ubuntu-24.04` auto-builds + releases a new `image-N` on **any push to
> main** (CircleCI; no cron — it only runs when something is pushed). A fresh build picks up the
> then-latest noble-stable kernel.

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
- `compose_24_04.sh` — rootfs → efi → overlay (`run-overlay.sh -f`) → dtb → nonhlos → assemble → zip.
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
# build (downloads ~1GB base on first run; later runs reuse ./.tmp/input)
make build_24.04 VERSIONS_FILE=./versions.json INPUT_REGION=RoW INPUT_VARIANT=headless
# output: ./.tmp/output/tachyon-ubuntu-24.04-RoW-headless-formfactor_dvt-9.9.999.zip

# flash
tachyon.sh edl
particle flash --tachyon ./.tmp/output/<the>.zip
```

A common failure and its cause are documented in `BUILDING.md` §9 (mostly: `PKG_linux_particle`
not matching the base kernel line — see §2 here).

---

## 6. Verification status

- A prior build of the **particle6** variant (base `image-21` + `PKG_linux_particle=…particle6`)
  was produced and **flashed successfully**; the boot chain was observed end-to-end
  (SBL1 → XBL → DTB → UFS → CDT → PMIC → systemd).
- The **particle2** configuration (base `image-22` + `PKG_linux_particle=…particle2`,
  the committed state) was built locally to confirm `check-pinned-packages` passes and a flashable
  zip is produced. <!-- RESULT: confirm before relying on this line -->

---

## 7. Known issues / next steps

1. **rootfs boot adaptation** — composer's rootfs was designed for U-Boot; under UEFI/new-BP it
   may need kernel cmdline / fstab / mount-point tweaks. The overlay stack is the place to add new
   mounts / msm blacklist (see eugene's `tachyon-console` stack). Validate a full boot-to-login on
   hardware, not just the boot chain.
2. **Matrix coverage** — only RoW/headless has been exercised locally. Extend to NA and desktop
   (`INPUT_REGION=NA` → nonhlos `na`; `INPUT_VARIANT=desktop`). The desktop base is larger and the
   `PKG_particle_tachyon_desktop_setup` pin pulls desktop deps — revisit the env pins per variant.
3. **CI** — `.github/workflows` still reflect the legacy flow assumptions in places; wire the
   self-hosted runner build to the new targets and confirm `make build_24.04` runs with `CI=true`.
4. **Cleanup opportunity** — once a base with particle2 baked in exists (or stays on image-22), the
   separate `fetch_kernel_deb` could be dropped by extracting `qcm6490-tachyon.dtb` directly from
   the overlaid rootfs instead of a standalone deb. Not done yet (kept explicit for clarity).
