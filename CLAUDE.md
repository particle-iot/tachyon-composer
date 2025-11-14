# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is the **Tachyon System Image Composer**, a build system for creating Tachyon System Images that upgrade from Ubuntu 20.04 base images to Ubuntu 24.04 with region-specific and variant-specific configurations. The build process runs inside Docker and produces flashable system images for Particle's Tachyon hardware platform (QCM6490-based).

For background documentation, see: https://developer.particle.io/tachyon/software/ubuntu_24_04/overview

## Core Commands

### Building System Images

```bash
# Basic build with versions.json
make build_24.04 \
  VERSIONS_FILE=./versions.json \
  INPUT_REGION=RoW \
  INPUT_VARIANT=desktop

# Full build with explicit parameters
make build_24.04 \
  INPUT_BASE_20_04_VERSION=1.0.170 \
  INPUT_REGION=RoW \
  INPUT_VARIANT=desktop \
  INPUT_UBOOT_VERSION=1.0.4 \
  INPUT_BASE_24_04_VERSION=14-276cd6b \
  INPUT_OVERLAY_STACK=ubuntu-headless-24.04 \
  INPUT_ENV_VARS="PKG_particle_linux=0.20.1-1,PKG_particle_tachyon_desktop_setup=2.7.0,PIN_PRIORITY=900"

# Enable debug mode for verbose output
make build_24.04 ... DEBUG=true
```

### Other Useful Commands

```bash
make help                    # Show all available commands
make version                 # Show current version
make clean                   # Remove temporary files
make doctor                  # Check prerequisites (docker, git)
make docker/shell            # Open interactive shell in builder container
make docker/rebuild          # Force rebuild of Docker image
```

### Fetching Individual Components

```bash
make fetch_20_04 INPUT_BASE_20_04_VERSION=1.0.170 INPUT_REGION=RoW INPUT_VARIANT=desktop
make fetch_uboot INPUT_UBOOT_VERSION=1.0.3
make fetch_24_04 INPUT_BASE_24_04_VERSION=14-276cd6b INPUT_VARIANT=desktop
make fetch_24_04_unxz        # Decompress the 24.04 .img.xz file
```

## Architecture

### Build Pipeline

The build process follows this sequence:

1. **Fetch Base Assets** - Downloads 20.04 base zip, U-Boot package, and 24.04 `.img.xz` from distribution servers
2. **Prepare 24.04 Base** (`prepare_base_24.04.sh`) - Unpacks 20.04 system image into a 24.04 staging directory, updates manifest.json
3. **Compose System Image** (`compose_24_04.sh`) - Core composition process:
   - Patches and signs bootloader (xbl.elf) using qtestsign
   - Extracts rootfs and EFI partition from 24.04 base image
   - Builds new rootfs.ext4 and efi.img with correct sizes
   - Updates XML partition tables (rawprogram*.xml files)
   - Applies overlays using tachyon-overlay-tool
4. **Package** - Zips the final system image directory

### Key Scripts

- **Makefile** - Main orchestrator; handles parameter validation, Docker builds, version resolution from git tags, and fetching of assets
- **compose_24_04.sh** - Core composition logic that runs inside Docker; handles bootloader patching, filesystem building, overlay application, and packaging
- **prepare_base_24.04.sh** - Prepares the 24.04 directory structure by unpacking 20.04 base and updating metadata
- **xml_tools.py** - Python utility for modifying XML partition tables (rawprogram*.xml files)

### Docker Build Environment

- **Dockerfile** - Ubuntu 24.04-based builder image with all necessary tools (python3, mkfs, xmllint, etc.)
- Builder runs as non-root user 'builder' with sudo access
- Host working directory mounted at `/project`
- Temporary files mounted at `/tmp/work` (maps to `./.tmp` on host)
- Version tracked via `particle-dockerfile-version` comment in Dockerfile (currently 1.3)

### External Tools Fetched at Build Time

- **qtestsign** - Cloned from https://github.com/msm8916-mainline/qtestsign for bootloader signing
- **tachyon-overlay-tool** - Cloned from https://github.com/particle-iot/tachyon-overlay-tool for applying filesystem overlays
- **tachyon-overlays** - Cloned from https://github.com/particle-iot/tachyon-overlays containing overlay stacks and configurations

### versions.json Structure

The `versions.json` file is the authoritative source for build component versions:

```json
{
  "sources": {
    "particle-iot/tachyon-u-boot": {"type": "cicd_release", "param": "1.0.5"},
    "particle-iot-inc/tachyon-release-builder": {"type": "cicd_release", "param": "1.0.175"},
    "particle-iot/tachyon-ubuntu-24.04": {"type": "git_release", "param": "18-32fd4db"},
    "particle-iot/tachyon-overlay": {"type": "git_release", "param": "HEAD"}
  },
  "env": {
    "PKG_particle_linux": "0.22.0-1",
    "PKG_particle_tachyon_desktop_setup": "2.7.0",
    "PIN_PRIORITY": "900"
  }
}
```

When `VERSIONS_FILE` is provided, the Makefile parses these values and overrides individual input parameters.

### Region and Variant Parameters

- **INPUT_REGION**: `NA` (North America) or `RoW` (Rest of World) - affects cellular modem configuration
- **INPUT_VARIANT**: `headless` or `desktop` - determines UI presence and package selection

## Important Implementation Details

### Bootloader Handling

The bootloader (xbl.elf) must be patched with U-Boot and then signed using qtestsign's fake test certificates. The process:
1. `patchxbl.py` patches xbl.elf with u-boot-dtb.bin
2. `qtestsign.py -v6 abl` signs the patched bootloader
3. Size is updated in rawprogram1.xml and rawprogram2.xml (for xbl_a and xbl_b)

### Filesystem Building

The rootfs.ext4 is created from the 24.04 base image with:
- Size aligned to full disk image size (4KiB alignment)
- LABEL and UUID preserved from source partition
- Built using `mkfs.ext4 -d` to populate from mounted source

The efi.img is:
- Sized based on `num_partition_sectors` from rawprogram XML
- FAT16 formatted with 4096-byte sectors
- Populated via rsync from source EFI partition

### Loop Device Mounting Strategy

The compose script handles two mounting scenarios:
1. **Standard**: Uses `/dev/loopXpY` partition nodes if available
2. **Fallback**: Creates offset-based loop devices using `losetup -o` if partition nodes don't appear in container

This ensures compatibility across different container environments.

### Overlay System

Overlays are applied in-place to the sys-img directory using tachyon-overlay-tool. The overlay system:
- Accepts comma-separated environment variables via `INPUT_ENV_VARS`
- Supports stacks (e.g., `ubuntu-headless-24.04`, `ubuntu-desktop-24.04`)
- Runs after filesystem building is complete
- Can pin package versions using `PKG_*` variables and `PIN_PRIORITY`

## Versioning and CI/CD

- Repository version comes from git tags (semantic versioning: x.y.z)
- The version of this repository IS the version of the generated binary
- GitHub Actions workflow tags on merge based on PR labels (`release:patch`, `release:minor`, `release:major`)
- Builds run on self-hosted `ubuntu-tachyon` runner when tags are pushed
- Pull request builds use `tag-sha` versions (e.g., `1.2.3-abcdef0`)

## File Locations

### Input Files (downloaded to `.tmp/input/`)
- `tachyon-ubuntu-20.04-{REGION}-{VARIANT}-formfactor_dvt-{VERSION}.zip`
- `tachyon-u-boot-{VERSION}.zip`
- `tachyon-ubuntu-24.04-{VARIANT}-image-{BUILD_ID}.img.xz`

### Output Files (created in `.tmp/output/`)
- `sys-img-24.04/` - Prepared system image directory
- `tachyon-ubuntu-24.04-{REGION}-{VARIANT}-formfactor_dvt-{VERSION}.zip` - Final packaged system image

### EDL Partition Structure
System images contain EDL (Emergency Download) flash files under `images/qcm6490/edl/`:
- `rawprogram*.xml` - Partition table definitions
- `xbl.elf` - Bootloader
- `qti-ubuntu-robotics-image-qcs6490-odk-sysfs_1.ext4` - Root filesystem
- `efi.img` - EFI boot partition
- Various other firmware blobs (ADSP, modem, etc.)

## Testing

When testing changes:
1. Use `DEBUG=true` to get verbose output
2. Check `.tmp/output/sys-img-24.04/manifest.json` for correct metadata
3. Verify partition sizes in `rawprogram*.xml` files match actual file sizes
4. Test both regions (NA/RoW) and variants (headless/desktop)
5. Use `make docker/shell` to debug issues interactively inside the container
