# Tachyon System Image Composer (26.04 / new-BP)

> **This is the `26.04` branch.** It builds **Tachyon Ubuntu 26.04** only. The 24.04
> composer lives on `main`; the two are kept apart on purpose (26.04 is the less-common
> track). Pull shared fixes in with `git merge main`.
>
> **Versioning:** 26.04 has its own version line (**1.3.x**), independent of 24.04's 1.2.x.
> Because git tags are repo-global, **release tags on this branch MUST be namespaced
> `26.04/x.y.z`** (e.g. `26.04/1.3.0`) — a bare `x.y.z` tag would pollute 24.04's version
> stream on `main`. CI resolves the version via `tachyon-resolve-version --tag-prefix
> "26.04/"` (see `.github/workflows/build.yml`). 26.04 **never** writes the served OTA
> channels (latest/stable); it only publishes prerelease artifacts and, when explicitly
> enabled, an un-served preview manifest.

A build system that composes flashable **Tachyon Ubuntu 26.04** EDL system images for the
QCM6490 (Quectel r108 baseband) platform. It takes a 26.04 base rootfs, the new BP firmware
artifact, and a kernel device tree, applies an overlay stack, **signs the boot/firmware blobs
itself with a selectable key**, and assembles an EDL-flashable image.

Boot chain: **XBL → UEFI (from bp-fw) → GRUB → Linux**. There is no Ubuntu 20.04 base, no
U-Boot, and no `qtestsign` — that legacy path has been retired.

> **Kernel note:** there is no `linux-qcom` kernel for resolute (26.04), so 26.04 ships the
> same Particle 6.8 kernel as 24.04 (built by `tachyon-ubuntu-24.04-kernel`; the noble deb
> installs cleanly on a resolute rootfs). Pins live in `versions-26.04.json`.

For background, see the
[Particle Tachyon Ubuntu 24.04 Overview](https://developer.particle.io/tachyon/software/ubuntu_24_04/overview).

---

## 📦 Prerequisites

- **GNU Make**
- **Docker** running (the build happens inside an Ubuntu 24.04 builder container)
- **~20 GB free disk** for inputs, intermediates, and output archives
- **Architecture**:
  - **ARM64/aarch64 host** — native execution (recommended; the signer is an aarch64 binary)
  - **x86_64/amd64 host** — needs QEMU user-mode ARM64 emulation (auto-configured on first build;
    `make setup_qemu` if it fails)
  - **macOS** — Docker Desktop handles ARM64 emulation automatically

---

## 🚀 Usage

```bash
# Build RoW / headless at version 1.2.0
make build_26.04 \
  VERSIONS_FILE=./versions-26.04.json \
  INPUT_REGION=RoW \
  INPUT_VARIANT=headless \
  OUTPUT_VERSION=1.2.0
```

`VERSIONS_FILE` is the authoritative source of component versions; the four required inputs
(`INPUT_REGION`, `INPUT_VARIANT`, and the 26.04 build id + overlay/signing config from
`versions-26.04.json`) drive the rest. Override any value on the `make` line.

The full release matrix is `{NA, RoW} × {headless, desktop}` — build all four for a release.

---

## ⚙️ Parameters

All parameters are `make` variables (`make build_26.04 VAR=value …`).

### Required
| Variable | Values | Notes |
|---|---|---|
| `INPUT_REGION` | `NA` \| `RoW` | Selects the region NON-HLOS firmware (`na`/`em`). |
| `INPUT_VARIANT` | `headless` \| `desktop` | `headless` == server. Selects the base image + default overlay stack. |
| `VERSIONS_FILE` | path | Source of truth for versions/signing/env. Default `versions-26.04.json`. |
| `INPUT_BASE_VERSION` | e.g. `22-938ac1d` | 26.04 base build id. Defaults from `versions-26.04.json` (`tachyon-ubuntu-26.04.param`). |

### Optional
| Variable | Default | Notes |
|---|---|---|
| `OUTPUT_VERSION` | `9.9.999` | Version stamped into the image/zip name. Set explicitly per build (e.g. `1.2.0`). |
| `OUTPUT_SYSTEM_IMAGE` | derived | `tachyon-ubuntu-26.04-<region>-<variant>-formfactor_dvt-<version>.zip`. |
| `SIGNING_PROFILE` | `test` (from `versions-26.04.json` `signing.profile`) | `test` \| `prod` \| `none`. See [Signing](#-signing). |
| `SIGNING_KEY` | from `versions-26.04.json` `signing.key` | Key name under `./keys/` (for `test`). |
| `INPUT_OVERLAY_STACK` | `ubuntu-<variant>-26.04` | Overlay stack to apply. |
| `INPUT_ENV` | from `versions-26.04.json` `env` block | Comma-separated `KEY=VAL` passed to the overlay tool (package pins, `PIN_PRIORITY`, …). |
| `BASE_CHANNEL` | `release` | `release` \| `prerelease` \| `preproduction` — channel for the 26.04 base image. |
| `DEBUG` | `false` | `true` enables `set -x` verbose tracing in the compose script. |
| `TMP_INPUT_DIR` / `TMP_OUTPUT_DIR` / `TMP_ROOT_DIR` | `./.tmp/...` | Working directories. |

> **`OUTPUT_VERSION` vs the git tag:** the repository's own `version` (from the latest semver
> git tag) identifies the *composer*; `OUTPUT_VERSION` is what gets stamped into the produced
> image. CI sets `OUTPUT_VERSION` from the resolved release/prerelease version automatically.

---

## 📄 `versions-26.04.json`

The authoritative inputs. Supports `//` line comments.

```jsonc
{
  "sources": {
    // New BP firmware — referenced as a published ARTIFACT ONLY (version + url), never as a
    // repo dependency. Ships bootbinaries, QCM6490 fw, and pre-built region NON-HLOS images.
    "bp-fw": { "version": "2.0.3", "url": "https://tachyon-ci.particle.io/release/tachyon-bp-fw-2.0.3.zip" },

    // 26.04 base rootfs (livecd-rootfs). Variants headless (==server) and desktop both published.
    "particle-iot/tachyon-ubuntu-26.04": { "type": "git_release", "param": "22-938ac1d" },

    // Kernel input (single source of truth) — provides qcm6490-tachyon.dtb AND pins the rootfs
    // kernel. MUST match PKG_linux_particle in env and the base image ABI.
    "particle-iot/tachyon-ubuntu-26.04-kernel": {
      "type": "s3_release", "param": "stable-6.8.0-1058.59particle2",
      "abi": "1058", "deb_version": "6.8.0-1058.59+particle2",
      "base_url": "https://linux-dist.particle.io/kernel/release"
    },

    "particle-iot/tachyon-overlay": { "type": "git_release", "param": "HEAD" }
  },

  // Composer-owned signing (selectable key).
  "signing": { "profile": "test", "key": "qti_presigned_certs-key2048_exp257_hashSHA384" },

  // Overlay env (package pins applied to the rootfs). PKG_linux_particle MUST equal the kernel
  // deb_version above and be installable on the base image ABI, or check-pinned-packages fails.
  "env": {
    "PKG_linux_particle": "6.8.0-1058.59+particle2",
    "PKG_particle_linux": "0.22.0-1",
    "PKG_particle_tachyon_desktop_setup": "2.7.0",
    "PKG_particle_tachyon_ril": "0.4.5-1",
    "PKG_particle_tachyon_syscon": "1.0.20-2",
    "PIN_PRIORITY": "900"
  }
}
```

The BP firmware repo is **never** a `versions-26.04.json` dependency — only its published artifact zip
(`url` + `version`) is consumed.

---

## 🔏 Signing

The composer **re-signs** every boot/firmware blob itself (the BP artifact ships them TEST-signed),
using a selectable profile/key. See [`scripts/signing/README.md`](./scripts/signing/README.md)
and [`keys/README.md`](./keys/README.md).

| `SIGNING_PROFILE` | Behaviour |
|---|---|
| `test` (default) | Re-signs with Qualcomm sectoolsv2 `--signing-mode TEST` (stock test keys). **Not production-secure.** |
| `prod` | `--signing-mode LOCAL` with an OEM key supplied at build time via `SIGNING_KEY_PATH` (a mounted dir, **never committed**). |
| `none` | Passthrough — keeps the BP test signing, signs nothing. |

After re-signing the individual blobs, `multi_image.mbn` is regenerated to vouch for the
re-signed hashes (it vouches for 10 boot blobs + ADSP/CDSP/WPSS from `QCM6490_fw`).

> ⚠️ **Only test keys may be committed.** Production/proprietary keys must be supplied at build
> time via secret/mount and never checked in. See `keys/README.md`.

---

## 🔄 Build Pipeline (`compose.sh`, in Docker)

1. **rootfs.ext4** — built from the 26.04 base `.img`, sized with headroom.
2. **Overlay stack** — `tachyon-overlay-tool` applies `ubuntu-<variant>-26.04` (packages,
   Particle services, kernel pin) using the `INPUT_ENV` pins.
3. **efi.img** — GRUB ESP (`scripts/efi/make-efi-img.sh`).
4. **dtb.img** — `qcm6490-tachyon.dtb` extracted from the kernel modules deb (`scripts/dtb/`).
5. **nonhlos.img** — region firmware (`em`/`na`), shipped pre-built in the bp-fw artifact.
6. **Sign** — `scripts/signing/sign.sh` re-signs the boot/fw blobs + regenerates `multi_image.mbn`.
7. **Assemble** — `scripts/assemble/` (ptool + `partition_ext.xml`) produces `rawprogram*/patch*`.
8. **Package** — `manifest.json` + zip → `.tmp/output/<OUTPUT_SYSTEM_IMAGE>`.

---

## 🛠 Commands

```
build_26.04                Build a Tachyon 26.04 EDL system image (new-BP)
fetch_base / _unxz        Download / decompress the 26.04 base .img.xz
fetch_bp_fw                Download bp-fw and split bootbinaries + fw + nonhlos images
fetch_kernel_deb           Download the kernel modules deb (for qcm6490-tachyon.dtb)
fetch_overlay_tool         Clone tachyon-overlay-tool inside Docker
fetch_tachyon_overlays     Clone tachyon-overlays inside Docker
vendor_sectools            Populate scripts/signing/sectools/ (signer; ~59MB)
docker/shell               Interactive shell in the builder container
docker/rebuild             Force-rebuild the builder image
version                    Show the composer version (from git tag)
doctor / check_qemu / setup_qemu / clean
help                       Full command + parameter list
```

`make clean` removes `./.tmp` (all inputs, intermediates, and relocated logs).

---

## 📂 Repository Layout

```
compose.sh        Core composition (runs in Docker)
prepare_base_24.04.sh   Base staging helper
Makefile                Orchestrator: fetch, validate, signing/matrix plumbing
versions-26.04.json           Authoritative component versions + signing + env
Dockerfile              Ubuntu 24.04 builder image
keys/                   Signing keys (TEST keys only — see keys/README.md)
scripts/
  efi/                  GRUB ESP image builder
  dtb/                  qcm6490-tachyon.dtb extractor / dtb.img builder
  assemble/             ptool + partition tables (rawprogram/patch generation)
  signing/              sign.sh + image-map + vendored sectoolsv2 (selectable-key signer)
```

---

## ⚡ CI/CD

GitHub Actions (`.github/workflows/build.yml`) builds the full matrix
`{RoW, NA} × {headless, desktop}` on the self-hosted `ubuntu-tachyon` runner:

- **Pull requests** → build all four, upload to the `prerelease/` channel, comment download links.
- **Semver tag push** (`x.y.z`) → build all four, upload to `releases/<version>/<region>/`,
  publish per-version metadata, and create a GitHub Release with changelog.

---

## 📲 Flashing the built image

See [`FLASHING.md`](FLASHING.md). Short version, from inside the unzipped image:

```bash
particle flash --tachyon
particle tachyon restore
```

There is no provisioning step, and `provision_ufs22.xml` must never be applied to a device
that already boots — it re-creates the LUN holding the modem's IMEI and calibration. The
manifest-driven form above always programs the right set of LUNs, including LUN 6, which the
firmware set moved to in 1.2.6.

## 🐛 Troubleshooting

`chroot: ... Exec format error` on x86_64 means QEMU ARM64 emulation isn't configured — run
`make setup_qemu`. See [TROUBLESHOOTING.md](./TROUBLESHOOTING.md).
