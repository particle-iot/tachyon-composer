# Tachyon System Image Composer

A build system for creating Tachyon System Images that upgrade from Ubuntu 20.04 base images to Ubuntu 24.04 with region-specific and variant-specific configurations.

For more background and documentation, see the [Particle Tachyon Ubuntu 24.04 Overview](https://developer.particle.io/tachyon/software/ubuntu_24_04/overview).

---

## 📦 Prerequisites

- **GNU Make** installed  
- **Docker** installed and running (the build happens inside Docker)  
- **Sufficient disk space** for temporary files and output archives (around 12GB)  

---

## 🚀 Usage

### Quick Start

```bash
# Display help and available commands
make help
```

### Build a 24.04 System Image (basic versioned build)

```bash
make build_24.04 \
  VERSIONS_FILE=./versions.json \
  INPUT_REGION=RoW \
  INPUT_VARIANT=desktop
```

### Build a 24.04 System Image (full parameters)

Using 20.04 base version `1.0.170`:

```bash
make build_24.04 \
  INPUT_BASE_20_04_VERSION=1.0.170 \
  INPUT_REGION=RoW \
  INPUT_VARIANT=desktop \
  INPUT_UBOOT_VERSION=1.0.4 \
  INPUT_BASE_24_04_VERSION=14-276cd6b \
  INPUT_OVERLAY_STACK=ubuntu-headless-24.04 \
  INPUT_ENV_VARS="PKG_particle_linux=0.20.1-1,PKG_particle_tachyon_desktop_setup=2.7.0,PKG_particle_tachyon_ril=0.4.5-1,PKG_particle_tachyon_syscon=1.0.19-1,PIN_PRIORITY=900"
```

---

## 🛠 Available Commands

### `build_24.04`
Builds a Tachyon System Image for Ubuntu 24.04 base.  
Requires both a 20.04 base zip (from Particle distribution) and a 24.04 `.img` (from CI).

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
- **`INPUT_BASE_20_04_VERSION`**: Semantic version of the 20.04 base zip (e.g., `1.0.167`)  
- **`INPUT_REGION`**: Target deployment region  
  - `NA` = North America  
  - `RoW` = Rest of World  
- **`INPUT_UBOOT_VERSION`**: Semantic version of U-Boot package (e.g., `1.0.3`)  
- **`INPUT_BASE_24_04_VERSION`**: Build identifier for the 24.04 base image (e.g., `14-276cd6b`)  
- **`VERSIONS_FILE`**: JSON file containing the official version mappings used to generate the release output. This is the authoritative source of truth for build versions.  

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

1. **Parameter Validation** – Ensures all required parameters are provided and valid.  
2. **Fetch Base Assets** – Downloads the 20.04 base zip, U-Boot, and the 24.04 `.img.xz`.  
3. **Decompression & Prep** – Decompresses 24.04 `.img.xz`, unpacks 20.04 system image into a 24.04 staging directory, updates manifest.  
4. **Compose** – Runs `compose_24_04.sh` inside Docker to patch bootloader, extract ADSP blobs, replace rootfs, build EFI image, update XML.  
5. **Package** – Zips the prepared `sys-img-24.04/` folder into the final output `.zip`.  

---

## 📂 Output

The build produces:

- A `.zip` archive containing the upgraded system image files (`OUTPUT_24_04_SYSTEM_IMAGE`)  
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
