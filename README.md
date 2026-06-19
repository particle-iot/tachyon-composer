# Tachyon System Image Composer

A Docker-based build system that produces an EDL-flashable Tachyon Ubuntu 24.04 factory image for the **new BP** (Quectel r108 / QCM6490, UEFI boot chain), with region-specific (`NA`/`RoW`) and variant-specific (`headless`/`desktop`) configurations.

For a step-by-step build guide, see [BUILDING.md](./BUILDING.md). For development conventions, see [AGENTS.md](./AGENTS.md). If you are picking up the new-BP migration, start with [HANDOFF.md](./HANDOFF.md).

For more background and documentation, see the [Particle Tachyon Ubuntu 24.04 Overview](https://developer.particle.io/tachyon/software/ubuntu_24_04/overview).

---

## 📦 Prerequisites

- **GNU Make** installed
- **Docker** installed and running (the build happens inside Docker)
- **Sufficient disk space** for temporary files and output archives (around 12GB)
- **Architecture requirements**:
  - **ARM64/aarch64 host**: Native execution (recommended for best performance)
  - **x86_64/amd64 host**: Requires QEMU user-mode emulation for ARM64 binaries

### x86_64 Host Setup

If you're building on an **x86_64/amd64** machine, QEMU ARM64 emulation is required and will be **automatically configured** on first build.

The build system will:
1. Detect your architecture
2. Check if QEMU is registered
3. Automatically set it up if needed using Docker

**Manual setup (optional):**
```bash
# Manually trigger QEMU setup
make setup_qemu

# Or directly:
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
```

This only needs to be done once per host machine and persists across reboots.

---

## 🚀 Usage

### Quick Start

```bash
# Display help and available commands
make help
```

### Build a 24.04 System Image

```bash
make build_24.04 \
  VERSIONS_FILE=./versions.json \
  INPUT_REGION=RoW \
  INPUT_VARIANT=headless
```

`versions.json` is the authoritative source of versions (base rootfs, bp-fw, kernel deb,
overlays) and apt pins. See [BUILDING.md](./BUILDING.md) §3 for its structure. The 24.04 base
build id and the overlays ref are read from it; you only need to pass `INPUT_REGION` and
`INPUT_VARIANT` on the command line (plus `OUTPUT_VERSION` for a release).

---

## 🛠 Available Commands

### `build_24.04`
Builds an EDL-flashable Tachyon Ubuntu 24.04 factory image (new BP / UEFI). Fetches the 24.04
base rootfs image, bp-fw release, kernel deb and overlays, then composes and assembles the
flashable `.zip` inside Docker.

### `help`
Displays usage information and examples.

### `version`
Shows the current version of the Tachyon System Image Composer as resolved by the CI/CD pipeline or the `Makefile`.

```bash
make version
# Example output: 1.2.3
```

### `clean`
Removes temporary files created during the build process.

---

## ⚙️ Parameters

### Required Parameters
- **`VERSIONS_FILE`**: JSON file with the authoritative version mappings (base rootfs, bp-fw,
  kernel deb, overlays) and apt pins. This is the source of truth for build versions.  
- **`INPUT_REGION`**: Target deployment region  
  - `NA` = North America (nonhlos firmware variant `na`)  
  - `RoW` = Rest of World (nonhlos firmware variant `em`)  
- **`INPUT_VARIANT`**: Image variant — `headless` or `desktop` (selects the base image and the
  default overlay stack `ubuntu-<variant>-24.04`).  
- **`INPUT_BASE_24_04_VERSION`**: Build identifier for the 24.04 base rootfs image (e.g.,
  `21-4d6898e`). Normally supplied via `VERSIONS_FILE`.  

### Optional Parameters
- **`OUTPUT_24_04_SYSTEM_IMAGE`**: Output filename for the final `.zip`  
  - Default: `tachyon-ubuntu-24.04-<region>-<variant>-formfactor_dvt-9.9.999.zip`  

- **`TMP_INPUT_DIR`**: Temporary input directory  
  - Default: `./.tmp/input`  

- **`TMP_OUTPUT_DIR`**: Temporary output directory  
  - Default: `./.tmp/output`  

---

## 📑 Examples

Use a custom temporary directory:

```bash
make build_24.04 TMP_INPUT_DIR=/scratch/tmp TMP_OUTPUT_DIR=/scratch/out ...
```

---

## 🔄 Build Process

1. **Parameter Validation** – Ensures required parameters are provided and valid.  
2. **Fetch Assets** – Downloads the 24.04 base rootfs `.img.xz`, the bp-fw release (split into
   `QCM6490_bootbinaries` + `QCM6490_fw`), the kernel deb, and clones the overlay tool + overlays.  
3. **Compose** (`compose_24_04.sh`, inside Docker) – Builds `rootfs.ext4` from the base, builds
   `efi.img`, applies the overlay stack to the rootfs (installs kernel + Particle packages),
   builds `dtb.img` (`qcm6490-tachyon.dtb`) and `nonhlos-<variant>.img`.  
4. **Assemble** – Runs `ptool` + `partition_ext.xml` to lay out the partitions
   (`system`/`efi`/`dtb_a`/`core_nhlos_a` + bootbinaries) into an EDL `rawprogram*/patch*` tree.  
5. **Package** – Zips the EDL tree into the final output `.zip`.  

See [BUILDING.md](./BUILDING.md) for the full step-by-step guide.

---

## 📂 Output

The build produces:

- A `.zip` archive containing the EDL-flashable factory image (`OUTPUT_24_04_SYSTEM_IMAGE`)  
- Logs of the build steps  
- Temporary work directories under `.tmp` (clean with `make clean`)  

---

## 🐛 Debug

You can debug any command by adding `DEBUG=true` at the end:

```bash
make build_24.04 ... DEBUG=true
```

---

## ❌ Error Handling

The Makefile validates:

- Missing required parameters
- Invalid region values (must be `NA` or `RoW`)
- Directory creation permissions
- Architecture compatibility and QEMU configuration

### Common Errors

#### "Exec format error" during build

**Symptom:**
```
chroot: failed to run command '/usr/bin/env': Exec format error
```

**Cause:** You're building on an x86_64 machine and QEMU ARM64 emulation setup failed.

**Solution:**

The build should automatically set up QEMU. If it fails, try manually:
```bash
make setup_qemu
```

Or if Docker is not working:
```bash
sudo apt-get install -y qemu-user-static binfmt-support
```

Then retry your build. See [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) for more details.

---

## 🏷 Versioning

- The **version of this project** (starting at **1.1.x**) is **also the version of the binary that is generated**. They are one and the same.  
- The **`VERSIONS_FILE`** is used to build the output of the release and defines the official version. This ensures that the build artifacts and the repository version stay perfectly aligned.  

You can also print the version locally:

```bash
make version
```

---

## ⚡ CI/CD Workflow

This repository uses **GitHub Actions** to automate builds and tagging.

- **Tag on Merge**  
  - When a PR is merged into `main`, the workflow calculates the next semantic version (`patch`/`minor`/`major`) based on PR labels (`release:patch`, `release:minor`, `release:major`).  
  - A new Git tag (`x.y.z`) is created and pushed automatically.  

- **Build on Tag**  
  - When a tag is pushed, the build workflow runs on a self-hosted `ubuntu-tachyon` runner.  
  - The workflow sets the version, runs `make build_24.04`, and produces the system image.  
  - Artifacts can be uploaded to GitHub Actions, S3, or GitHub Releases depending on configuration.  

- **Pull Request Builds**  
  - On pull requests, the workflow builds with a `tag-sha` version (e.g., `1.2.3-abcdef0`) to validate changes.  
  - Optionally, a comment is posted to the PR with artifact links for testing.  

This ensures **consistent versioning**, **reproducible builds**, and **automatic packaging** on every merge or release.

---

## 🙋 Support

For issues or questions regarding the Tachyon System Image Composer, please refer to the project documentation or contact the development team.
