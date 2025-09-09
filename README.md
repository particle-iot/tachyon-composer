# Tachyon System Image Composer

A build system for creating Tachyon System Images based on Ubuntu distributions.

## Overview

This repository contains a Makefile for building Tachyon System Images that upgrade from Ubuntu 20.04 base images to Ubuntu 24.04 with region-specific and variant-specific configurations.

## Prerequisites

- Make utility installed on your system
- Sufficient disk space for temporary files and output images

## Usage

### Quick Start

```bash
# Display help and available commands
make help

# Build a basic system image
make build_24.04 INPUT_BASE_VERSION=1.0.2 REGION=NA VARIANT=headless

# Build with custom output filename
make build_24.04 INPUT_BASE_VERSION=1.0.2 REGION=RoW VARIANT=desktop OUTPUT_FILE=my-image.img
```

### Available Commands

#### `build_24.04`
Builds a Tachyon System Image for Ubuntu 24.04 base. This is currently the only supported build command.

#### `help`
Displays usage information and examples.

#### `version`
Shows the current version of the Tachyon System Image Composer.

#### `clean`
Removes temporary files created during the build process.

### Parameters

#### Required Parameters

- **INPUT_BASE_VERSION**: Version of the base system image for Ubuntu 20.04 (e.g., `1.0.2`)
- **REGION**: Target deployment region
  - `NA` - North America
  - `RoW` - Rest of World
- **VARIANT**: System configuration variant
  - `headless` - Server/headless configuration
  - `desktop` - Desktop configuration with GUI

#### Optional Parameters

- **OUTPUT_FILE**: Custom output filename
  - Default: `tachyon-system-image-<version>-<region>-<variant>.img`
  - Example: `tachyon-system-image-1.0.2-NA-headless.img`
- **TMP_DIR**: Temporary directory for build files
  - Default: `./tmp`

### Examples

```bash
# Basic headless build for North America
make build_24.04 INPUT_BASE_VERSION=1.0.2 REGION=NA VARIANT=headless

# Desktop build for Rest of World with custom output
make build_24.04 INPUT_BASE_VERSION=1.0.2 REGION=RoW VARIANT=desktop OUTPUT_FILE=tachyon-desktop-row.img

# Build with custom temporary directory
make build_24.04 INPUT_BASE_VERSION=1.0.2 REGION=NA VARIANT=headless TMP_DIR=/tmp/tachyon-build

# Display version information
make version

# Clean up temporary files
make clean
```

## Build Process

The build process consists of the following steps:

1. **Parameter Validation**: Ensures all required parameters are provided and valid
2. **Environment Setup**: Creates temporary directories and validates the build environment
3. **Base Image Preparation**: Configures the Ubuntu 20.04 base image with the specified version
4. **System Modifications**: Applies Tachyon-specific modifications and upgrades to Ubuntu 24.04
5. **Region Configuration**: Applies region-specific settings (NA or RoW)
6. **Variant Configuration**: Configures the system for the specified variant (headless or desktop)
7. **Image Generation**: Creates the final system image file

## Output

The build process generates:
- A system image file (`.img`) containing the configured Tachyon system
- Build logs showing the progress and configuration used
- Temporary files in the specified temporary directory (cleaned up with `make clean`)

## Error Handling

The Makefile includes validation for:
- Missing required parameters
- Invalid region values (must be `NA` or `RoW`)
- Invalid variant values (must be `headless` or `desktop`)
- Directory creation permissions

## Version

Current version: 1.0.0

## Support

For issues or questions regarding the Tachyon System Image Composer, please refer to the project documentation or contact the development team.