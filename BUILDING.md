# Building a Tachyon System Image

This document is a step-by-step guide to producing a **flashable Tachyon Ubuntu 24.04 factory
image** (the **new BP**: Quectel r108 / QCM6490, UEFI boot chain) from this repository.

> This describes only the in-repo build flow. It does not cover how to obtain the protected base
> assets (the 24.04 base image, bp-fw release, kernel deb) — those come from Particle's CI/S3.

---

## 1. Prerequisites

### 1.1 Host tools

- OS: Linux (x86_64 recommended; an arm64 host runs natively without QEMU).
- Installed and working:
  - `git`
  - `docker` (daemon running, able to `docker run`)
  - `make` (GNU Make)
- Disk space: at least **12GB** (downloaded base image, the `.tmp/` work dir and the output ZIP).
- Network access to Particle's image/package endpoints and GitHub (for `tachyon-overlay-tool`
  and `tachyon-overlays`).
- On an **x86_64** host, the build auto-registers QEMU arm64 emulation on first run (the rootfs
  overlay runs an arm64 chroot). You can pre-register with `make setup_qemu`.

### 1.2 Quick self-check

```bash
make doctor
```

Checks that `docker`, `git` and QEMU arm64 emulation are available on the host.

---

## 2. Get the repo and pick a version

```bash
git clone <repo-url> tachyon-composer
cd tachyon-composer
git checkout 1.2.3      # optional: build a tagged release
make version            # prints the version resolved from the git tag
```

The repo version (git tag, `x.y.z`) is also the version of the generated image.

---

## 3. Version inputs (`versions.json`)

`versions.json` is the **authoritative source of truth** for what goes into the image. It has two
sections: `sources` (where each component comes from) and `env` (apt pins applied to the rootfs).

```json
{
  "sources": {
    "particle-iot-inc/tachyon-quectel-bp-fw-sdk-r108": {
      "type": "s3_release", "param": "2.0.0",
      "url": "https://tachyon-ci.particle.io/release/tachyon-bp-fw-2.0.0.zip"
    },
    "particle-iot/tachyon-ubuntu-24.04-kernel": {
      "type": "s3_release", "param": "stable-6.8.0-1058.59particle2",
      "abi": "1058", "deb_version": "6.8.0-1058.59+particle2",
      "base_url": "https://linux-dist.particle.io/kernel/release"
    },
    "particle-iot/tachyon-ubuntu-24.04": { "type": "git_release", "param": "21-4d6898e" },
    "particle-iot/tachyon-overlay":      { "type": "git_release", "param": "HEAD" }
  },
  "env": {
    "PKG_linux_particle": "6.8.0-1056.57+particle6",
    "PKG_particle_linux": "0.22.0-1",
    "PKG_particle_tachyon_desktop_setup": "2.7.0",
    "PKG_particle_tachyon_ril": "0.4.5-1",
    "PKG_particle_tachyon_syscon": "1.0.20-2",
    "PIN_PRIORITY": "900"
  }
}
```

What each `sources` entry controls:

| Key | Used for |
|---|---|
| `tachyon-quectel-bp-fw-sdk-r108` | bp-fw release zip → `QCM6490_bootbinaries` (boot chain) + `QCM6490_fw` |
| `tachyon-ubuntu-24.04-kernel` | kernel deb (S3) → `qcm6490-tachyon.dtb` for the `dtb_a` partition |
| `tachyon-ubuntu-24.04` | the 24.04 **base rootfs** build id (`INPUT_BASE_24_04_VERSION`) |
| `tachyon-overlay` | the overlays repo ref applied to the rootfs |

What `env` controls: each `PKG_*` becomes an apt version pin applied to the rootfs by the
overlay stack (`pin-pkg-versions` → `check-pinned-packages`).

> **Important — keep the kernel pin consistent with the base.**
> `PKG_linux_particle` pins the kernel **inside the rootfs**. The 24.04 base already ships a
> specific kernel ABI; `check-pinned-packages` will FAIL if it cannot install the pinned version
> on top of that base (e.g. pinning a `1058` kernel onto a `1056` base). Set `PKG_linux_particle`
> to match the base's kernel line. The `sources` kernel entry (used only to extract
> `qcm6490-tachyon.dtb`) may point at a newer tag independently — see the new-BP handoff for the
> current rootfs-vs-dtb version state.

---

## 4. Build the Docker builder image (one-time)

```bash
make docker/build
```

Builds `tachyon-system-image-builder:<version-from-Dockerfile-comment>`. `build_24.04` triggers
this automatically when needed.

---

## 5. Run the full build

```bash
make build_24.04 \
  VERSIONS_FILE=./versions.json \
  INPUT_REGION=RoW \
  INPUT_VARIANT=headless \
  OUTPUT_VERSION=1.0.0 \
  DEBUG=false
```

- `VERSIONS_FILE`: the `versions.json` above (authoritative versions + env pins).
- `INPUT_REGION`: `NA` or `RoW` (maps to nonhlos firmware variant `na` / `em`).
- `INPUT_VARIANT`: `headless` or `desktop` (selects the 24.04 base image and the default
  overlay stack `ubuntu-<variant>-24.04`).
- `OUTPUT_VERSION`: optional; defaults to `9.9.999`. Goes into the output filename.
- `DEBUG`: `true` enables `set -x` and more verbose logs.

In CI, set `CI=true` so the container runs without `-it` (avoids "the input device is not a TTY").

### What `build_24.04` does

`make build_24.04` runs, in order:

1. **version / print-config / check_qemu** — print the resolved versions and ensure QEMU.
2. **fetch_24_04_unxz** — download and decompress the 24.04 base `.img.xz`
   (`tachyon-ubuntu-24.04-<variant>-image-<base-id>.img.xz`).
3. **fetch_bp_fw** — download the bp-fw release and split it into `QCM6490_bootbinaries.zip`
   and `QCM6490_fw.zip`.
4. **fetch_kernel_deb** — download the kernel modules deb (for `qcm6490-tachyon.dtb`).
5. **fetch_overlay_tool / fetch_tachyon_overlays** — clone the overlay tool and overlays.
6. **docker/build** — ensure the builder image exists.
7. **compose_24_04.sh** (inside Docker) — the actual image build:
   1. `rootfs.ext4` from the 24.04 base `.img` (+3GB headroom for overlay packages).
   2. `efi.img` from the vendored GRUB ESP (`build-efi/`).
   3. Apply the overlay stack to `rootfs.ext4` via `run-overlay.sh -f <ext4>` (installs the
      kernel + Particle packages, applies the apt pins).
   4. `dtb.img` — extract `qcm6490-tachyon.dtb` from the kernel deb (`build-dtb/`).
   5. `nonhlos-<variant>.img` — pack the region firmware blobs (`build-nonhlos/`).
   6. Assemble with `ptool` + `partition_ext.xml` (`assemble/`) → `rawprogram*/patch*`.
   7. Zip the EDL tree into the output `.zip`.

---

## 6. Output

Default output (unless `TMP_OUTPUT_DIR` is overridden):

- Work/output root: `./.tmp/output/`
- Final ZIP: `./.tmp/output/tachyon-ubuntu-24.04-<REGION>-<VARIANT>-formfactor_dvt-<OUTPUT_VERSION>.zip`

```bash
ls -lh ./.tmp/output/*.zip
```

The ZIP is an EDL flash tree: `rawprogram*.xml`, `patch*.xml`, the `QCM6490_bootbinaries`,
`system`/`efi`/`dtb_a`/`core_nhlos_a` images, etc.

---

## 7. Flash and verify

On a host with the `particle` CLI and the device attached:

```bash
# put the device into EDL (QDL 9008) mode
tachyon.sh edl

# flash the factory image
particle flash --tachyon ./.tmp/output/tachyon-ubuntu-24.04-RoW-headless-formfactor_dvt-1.0.0.zip
```

---

## 8. Clean and rebuild

```bash
make clean          # remove ./.tmp (downloads + output); keeps the Docker image
make docker/clean   # remove the builder image
make docker/build   # rebuild it
```

> The fetch steps are file-target based: once a base image / bp-fw / kernel deb is downloaded
> under `./.tmp/input`, re-running `build_24.04` reuses it and only re-runs the compose stage.

---

## 9. Debugging

- Add `DEBUG=true` to any build command for `set -x` and richer error context.
- Enter the container to iterate on the compose logic:

```bash
make docker/shell
# inside: working dir is /project, ./.tmp is mounted at /tmp/work
./compose_24_04.sh <base-img-basename> <output.zip> <em|na> <stack> <overlays-path> <env> <debug>
```

### Common issues

- **`check-pinned-packages` fails** — the pinned package versions in `versions.json` `env` cannot
  be installed on the chosen base. Most often `PKG_linux_particle` does not match the base's
  kernel ABI. See §3.
- **Download failed / empty file** — check network/access and retry; the fetch targets use
  retrying `curl`.
- **`Exec format error` in the chroot** — QEMU arm64 emulation is not registered on an x86_64
  host. Run `make setup_qemu`.
- **Out of disk space** — free space or point `TMP_ROOT_DIR` at a larger disk.

---

For development conventions when changing the build flow itself, see `AGENTS.md`.
