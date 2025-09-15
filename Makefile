# Tachyon System Image Composer
# Version: 1.0.0

# Derive VERSION from the latest semantic tag in the repo
VERSION := $(shell \
  tag=$$(git describe --tags --abbrev=0 2>/dev/null || echo ""); \
  if echo "$$tag" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$'; then \
    echo $$tag; \
  elif [ -z "$$tag" ]; then \
    echo "Error: No version tag found. Please create one (e.g. git tag 0.1.0)" >&2; \
    exit 1; \
  else \
    echo "Error: Latest tag '$$tag' is not a valid semantic version (x.y.z)" >&2; \
    exit 1; \
  fi)

# Default values
DEFAULT_OUTPUT_PREFIX := tachyon-ubuntu
DEFAULT_TMP_ROOT_DIR := ./.tmp
DEFAULT_TMP_INPUT_DIR := ./.tmp/input
DEFAULT_TMP_OUTPUT_DIR := ./.tmp/output

# Parameters (overridable)
COMMAND ?=
INPUT_BASE_20_04_VERSION ?=         # semver, e.g., 1.0.167
INPUT_REGION ?=                     # NA | RoW
INPUT_VARIANT ?=                    # headless | desktop
INPUT_UBOOT_VERSION ?=              # semver, e.g., 1.0.3
INPUT_BASE_24_04_VERSION ?=         # e.g., 14-276cd6b
OUTPUT_24_04_SYSTEM_IMAGE ?= $(DEFAULT_OUTPUT_PREFIX)-24.04-$(INPUT_REGION)-$(INPUT_VARIANT)-formfactor_dvt-9.9.999.zip

# Working variables
TMP_ROOT_DIR ?= $(DEFAULT_TMP_ROOT_DIR)
TMP_INPUT_DIR ?= $(DEFAULT_TMP_INPUT_DIR)
TMP_OUTPUT_DIR ?= $(DEFAULT_TMP_OUTPUT_DIR)
BUILD_SCRIPT := $(TMP_INPUT_DIR)/build_24.04.sh

# -------------------------------------------------------------------
# Validation helpers
# -------------------------------------------------------------------
define check_required_param
	@if [ -z "$($(1))" ]; then \
		echo "Error: $(1) parameter is required"; \
		echo "Usage: make $(COMMAND) INPUT_BASE_20_04_VERSION=<x.y.z> INPUT_REGION=<NA|RoW> INPUT_VARIANT=<headless|desktop> INPUT_UBOOT_VERSION=<x.y.z> INPUT_BASE_24_04_VERSION=<build-id> [OUTPUT_24_04_SYSTEM_IMAGE=<filename>] [TMP_INPUT_DIR=<dir>]"; \
		exit 1; \
	fi
endef

define validate_region
	@if [ "$(INPUT_REGION)" != "NA" ] && [ "$(INPUT_REGION)" != "RoW" ]; then \
		echo "Error: INPUT_REGION must be either 'NA' or 'RoW', got '$(INPUT_REGION)'"; \
		exit 1; \
	fi
endef

define validate_variant
	@if [ "$(INPUT_VARIANT)" != "headless" ] && [ "$(INPUT_VARIANT)" != "desktop" ]; then \
		echo "Error: INPUT_VARIANT must be either 'headless' or 'desktop', got '$(INPUT_VARIANT)'"; \
		exit 1; \
	fi
endef

define validate_semver
	@if ! echo "$($(1))" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$'; then \
		echo "Error: $(1) must be a semantic version (x.y.z), got '$($(1))'"; \
		exit 1; \
	fi
endef

define validate_output_24_04
	@if [ -z "$(OUTPUT_24_04_SYSTEM_IMAGE)" ]; then \
		echo "Error: OUTPUT_24_04_SYSTEM_IMAGE not set and no default provided."; \
		exit 1; \
	fi
endef

# -------------------------------------------------------------------
# Derived filenames/URLs
# -------------------------------------------------------------------
# 20.04 base zip name and URL (depends on region/variant/semver)
BASE20_FILENAME := tachyon-ubuntu-20.04-$(INPUT_REGION)-$(INPUT_VARIANT)-formfactor_dvt-$(INPUT_BASE_20_04_VERSION).zip
BASE20_URL := https://linux-dist.particle.io/release/$(BASE20_FILENAME)
BASE20_ZIP := $(TMP_INPUT_DIR)/$(BASE20_FILENAME)

# U-Boot zip (semver)
UBOOT_FILENAME := tachyon-u-boot-$(INPUT_UBOOT_VERSION).zip
UBOOT_URL_PRIMARY := https://linux-dist.particle.io/release/$(UBOOT_FILENAME)
UBOOT_URL_ENCODED := https://linux-dist.particle.io/release%2F$(UBOOT_FILENAME)
UBOOT_ZIP := $(TMP_INPUT_DIR)/$(UBOOT_FILENAME)
UBOOT_DIR := u-boot

# 24.04 base .img.xz and .img (variant + "build-id" fragment)
# Example: tachyon-ubuntu-24.04-headless-image-14-276cd6b.img.xz
BASE24_XZ_FILENAME := tachyon-ubuntu-24.04-$(INPUT_VARIANT)-image-$(INPUT_BASE_24_04_VERSION).img.xz
BASE24_URL := https://tachyon-ci.particle.io/release/$(BASE24_XZ_FILENAME)
BASE24_XZ := $(TMP_INPUT_DIR)/$(BASE24_XZ_FILENAME)
BASE24_IMG := $(TMP_INPUT_DIR)/$(basename $(BASE24_XZ_FILENAME))
BASE24_SYSTEM_IMAGE_DIR := sys-img-24.04

# -------------------------------------------------------------------
# Help
# -------------------------------------------------------------------
.PHONY: help
help:
	@echo "Tachyon System Image Composer v$(VERSION)"
	@echo ""
	@echo "Available commands:"
	@echo "  build_24.04                 Build a Tachyon System Image for Ubuntu 24.04 base"
	@echo "  fetch_20_04                 Download Ubuntu 20.04 base zip to $(TMP_INPUT_DIR)"
	@echo "  fetch_uboot                 Download U-Boot zip to $(TMP_INPUT_DIR)"
	@echo "  fetch_24_04                 Download Ubuntu 24.04 .img.xz to $(TMP_INPUT_DIR)"
	@echo "  fetch_24_04_unxz            Decompress 24.04 .img.xz to .img using Docker"
	@echo "  doctor                      Minimal host prerequisites check (docker, git)"
	@echo ""
	@echo "Required parameters:"
	@echo "  INPUT_BASE_20_04_VERSION    Base 20.04 version (semver, e.g., 1.0.167)"
	@echo "  INPUT_REGION                NA or RoW"
	@echo "  INPUT_VARIANT               headless or desktop"
	@echo "  INPUT_UBOOT_VERSION         U-Boot version (semver, e.g., 1.0.3)"
	@echo "  INPUT_BASE_24_04_VERSION    24.04 base build id (e.g., 14-276cd6b)"
	@echo ""
	@echo "Optional parameters:"
	@echo "  TMP_INPUT_DIR							 Temporary directory (default: ./tmp)"
	@echo "  OUTPUT_24_04_SYSTEM_IMAGE   Output filename"
	@echo ""
	@echo "Examples:"
	@echo "  make build_24.04 COMMAND=build_24.04 INPUT_BASE_20_04_VERSION=1.0.167 INPUT_REGION=RoW INPUT_VARIANT=desktop INPUT_UBOOT_VERSION=1.0.3 INPUT_BASE_24_04_VERSION=14-276cd6b"
	@echo "  make fetch_20_04 INPUT_BASE_20_04_VERSION=1.0.167 INPUT_REGION=RoW INPUT_VARIANT=desktop"

# -------------------------------------------------------------------
# Fetch targets (run inside Docker)
# -------------------------------------------------------------------
.PHONY: fetch_20_04 fetch_uboot fetch_24_04 fetch_24_04_unxz

fetch_20_04: $(BASE20_ZIP)
$(BASE20_ZIP):
	$(call check_required_param,INPUT_BASE_20_04_VERSION)
	$(call check_required_param,INPUT_REGION)
	$(call check_required_param,INPUT_VARIANT)
	$(call validate_region)
	$(call validate_variant)
	$(call validate_semver,INPUT_BASE_20_04_VERSION)
	@$(DOCKER_RUN) bash -lc 'set -euo pipefail; \
		mkdir -p "$(TMP_INPUT_DIR)"; \
		if [ -f "$@" ]; then \
			echo "File $@ already exists, skipping download"; \
			exit 0; \
		fi; \
		echo "==> Downloading 20.04 base: $(BASE20_URL) to $(TMP_INPUT_DIR)"; \
		curl -fL --retry 3 -o "$@" "$(BASE20_URL)" || { echo "Error: failed to download $(BASE20_URL)"; rm -f "$@"; exit 1; }; \
		test -s "$@" || { echo "Error: downloaded file is empty: $@"; exit 1; }; \
		echo "Downloaded 20.04: $@"; \
		unzip -o "$@" -d "$(TMP_INPUT_DIR)/sys-img-20.04"; \
		echo "Unzipped 20.04 base to $(TMP_INPUT_DIR)/sys-img-20.04"'


fetch_uboot: $(UBOOT_ZIP)
$(UBOOT_ZIP):
	$(call check_required_param,INPUT_UBOOT_VERSION)
	$(call validate_semver,INPUT_UBOOT_VERSION)
	@$(DOCKER_RUN) bash -lc 'set -euo pipefail; \
		mkdir -p "$(TMP_INPUT_DIR)"; \
		if [ -f "$@" ]; then \
			echo "File $@ already exists, skipping download"; \
			exit 0; \
		fi; \
		echo "==> Downloading U-Boot: $(UBOOT_URL_PRIMARY) (fallback: encoded path)"; \
		{ curl -fL --retry 3 -o "$@" "$(UBOOT_URL_PRIMARY)" || curl -fL --retry 3 -o "$@" "$(UBOOT_URL_ENCODED)"; } \
		  || { echo "Error: failed to download U-Boot from both $(UBOOT_URL_PRIMARY) and $(UBOOT_URL_ENCODED)"; rm -f "$@"; exit 1; }; \
		test -s "$@" || { echo "Error: downloaded file is empty: $@"; exit 1; }; \
		echo "Downloaded uboot: $@"; \
		unzip -o "$@" -d "$(TMP_INPUT_DIR)/u-boot" >/dev/null; \
		echo "Unzipped U-Boot to $(TMP_INPUT_DIR)/u-boot"'


fetch_24_04: $(BASE24_XZ)
$(BASE24_XZ):
	$(call check_required_param,INPUT_BASE_24_04_VERSION)
	$(call check_required_param,INPUT_VARIANT)
	$(call validate_variant)
	@$(DOCKER_RUN) bash -lc 'set -euo pipefail; \
		mkdir -p "$(TMP_INPUT_DIR)"; \
		if [ -f "$@" ]; then \
			echo "File $@ already exists, skipping download"; \
			exit 0; \
		fi; \
		echo "==> Downloading 24.04 base (xz): $(BASE24_URL)"; \
		curl -fL --retry 3 -o "$@" "$(BASE24_URL)" || { echo "Error: failed to download $(BASE24_URL)"; rm -f "$@"; exit 1; }; \
		test -s "$@" || { echo "Error: downloaded file is empty: $@"; exit 1; }; \
		echo "Downloaded 24.04: $@"'


# Decompress the .img.xz -> .img via Docker
fetch_24_04_unxz: fetch_24_04 docker/build $(BASE24_IMG)
$(BASE24_IMG): $(BASE24_XZ)
	@$(DOCKER_RUN) bash -lc 'set -euo pipefail; \
		echo "==> Decompressing $(notdir $<) -> $(notdir $@) using Docker from $(TMP_INPUT_DIR)"; \
		cd "$(TMP_INPUT_DIR)"; \
		if [ -f "$(notdir $@)" ]; then \
			echo "File $(notdir $@) already exists, skipping decompression"; \
			exit 0; \
		fi; \
		xz -T0 -d -k -v "$(notdir $<)"; \
		test -s "$(notdir $@)" || { echo "Error: decompression failed, missing $(notdir $@)"; exit 1; }; \
		echo "Decompressed: $(notdir $@)"'

# -------------------------------------------------------------------
# Prepare 24.04 base folder
# -------------------------------------------------------------------

# Prepare a 24.04 base folder by unzipping the 20.04 source base into it,
# copying the 24.04 .img alongside, and updating manifest.json fields.
.PHONY: prepare_base_24_04
prepare_base_24_04: fetch_20_04 fetch_24_04_unxz docker/build
	@$(DOCKER_RUN) bash -lc '\
		set -euo pipefail; \
		TMP_OUTPUT_DIR="/tmp/work/output" \
		TMP_INPUT_DIR="/tmp/work/input" \
		BASE24_SYSTEM_IMAGE_DIR="$(BASE24_SYSTEM_IMAGE_DIR)" \
		BASE20_ZIP="/tmp/work/input/$(notdir $(BASE20_ZIP))" \
		BASE24_IMG="/tmp/work/input/$(notdir $(BASE24_IMG))" \
		INPUT_BASE_24_04_VERSION="$(INPUT_BASE_24_04_VERSION)" \
		DEBUG="$${DEBUG:-false}" \
		./prepare_base_24.04.sh'

# -------------------------------------------------------------------
# qtools (qtestsign) fetch/setup inside Docker
# -------------------------------------------------------------------

#the dir INSIDE the container where qtools will be cloned
QTOOLS_DIR        := /tmp/work/tools/qtestsign

#use the HTTPS URL
QTOOLS_CLONE_URL = https://github.com/msm8916-mainline/qtestsign.git

# pin to a branch/tag/commit: QTOOLS_REF=main (or a sha) etc...
QTOOLS_REF        ?= main
QTOOLS_STAMP      := $(QTOOLS_DIR)/.installed

.PHONY: fetch_qtools
fetch_qtools: $(QTOOLS_STAMP)

# Clone and install qtestsign requirements inside the builder container
$(QTOOLS_STAMP): docker/build
	@echo "==> Setting up qtestsign (qtools) inside Docker"
	@mkdir -p "$(QTOOLS_DIR)"
	@$(DOCKER_RUN) bash -lc 'set -euo pipefail; \
		if [ ! -d "$(QTOOLS_DIR)/.git" ]; then \
			git clone --depth 1 "$(QTOOLS_CLONE_URL)" "$(QTOOLS_DIR)"; \
		else \
			echo "$(QTOOLS_DIR) already present"; \
		fi; \
		git -C "$(QTOOLS_DIR)" fetch --depth 1 origin "$(QTOOLS_REF)"; \
		git -C "$(QTOOLS_DIR)" checkout -q FETCH_HEAD; \
		pip3 install --user --no-cache-dir -r "$(QTOOLS_DIR)/requirements.txt" || \
		  sudo pip3 install --break-system-packages --no-cache-dir -r "$(QTOOLS_DIR)/requirements.txt"; \
		{ test -f "$(QTOOLS_DIR)/patchxbl.py" && test -f "$(QTOOLS_DIR)/qtestsign.py"; } \
		  || { echo "Error: qtestsign scripts not found in $(QTOOLS_DIR)"; exit 1; }; \
		touch "$(QTOOLS_DIR)/.installed"'
	@echo "Installed qtools to $(QTOOLS_DIR)"

# -------------------------------------------------------------------
# Main build command for Ubuntu 24.04
# -------------------------------------------------------------------
# Helper basenames for use inside the container
BASE24_IMG_BASENAME := $(notdir $(BASE24_IMG))

.PHONY: build_24.04
build_24.04: version fetch_qtools fetch_20_04 fetch_uboot fetch_24_04_unxz prepare_base_24_04 docker/build
	@echo "Building Tachyon System Image for Ubuntu 24.04..."
	@echo ""
	$(call check_required_param,INPUT_BASE_20_04_VERSION)
	$(call check_required_param,INPUT_REGION)
	$(call check_required_param,INPUT_VARIANT)
	$(call check_required_param,INPUT_UBOOT_VERSION)
	$(call check_required_param,INPUT_BASE_24_04_VERSION)
	$(call validate_region)
	$(call validate_variant)
	$(call validate_semver,INPUT_BASE_20_04_VERSION)
	$(call validate_semver,INPUT_UBOOT_VERSION)
	$(call validate_output_24_04,OUTPUT_24_04_SYSTEM_IMAGE)
	@echo "Configuration:"
	@echo "  Base 20.04 Version: $(INPUT_BASE_20_04_VERSION)"
	@echo "  24.04 Base Build:   $(INPUT_BASE_24_04_VERSION)"
	@echo "  Region:             $(INPUT_REGION)"
	@echo "  Variant:            $(INPUT_VARIANT)"
	@echo "  U-Boot Version:     $(INPUT_UBOOT_VERSION)"
	@echo "  Output File:        $(OUTPUT_24_04_SYSTEM_IMAGE)"
	@echo "  Temp Directory:     $(TMP_INPUT_DIR)"
	@echo "  Temp Output Dir:    $(TMP_OUTPUT_DIR)"
	@echo "  Debug:       			 $(DEBUG)"
	@echo ""
	@mkdir -p $(TMP_INPUT_DIR)
	@mkdir -p $(TMP_OUTPUT_DIR)
	@echo "Step 1: Base assets available in $(TMP_INPUT_DIR)"
	@echo "  - 20.04: $(notdir $(BASE20_ZIP)) in $(TMP_INPUT_DIR)/sys-img-20.04"
	@echo "  - U-Boot: $(notdir $(UBOOT_ZIP)) in $(TMP_INPUT_DIR)/u-boot"
	@echo "  - 24.04 img: $(notdir $(BASE24_IMG)) in $(TMP_INPUT_DIR)/sys-img-24.04"
	@echo ""
	@$(DOCKER_RUN) bash ./compose_24_04.sh "$(UBOOT_DIR)" "$(BASE24_IMG_BASENAME)" "$(BASE24_SYSTEM_IMAGE_DIR)" "$(OUTPUT_24_04_SYSTEM_IMAGE)" "$(DEBUG)"
	@echo ""
	@echo "Build completed successfully!"
	@echo "Output: $(abspath $(TMP_OUTPUT_DIR))/$(notdir $(OUTPUT_24_04_SYSTEM_IMAGE))"

##########################################################
# Docker-related targets
###########################################################

# --- Docker image build targets (self-contained, no build.sh) -----------------

DOCKERFILE           ?= Dockerfile
DOCKER_CONTEXT       ?= .

define GET_COMMENT_KV
sed -nE 's/^[[:space:]]*#[[:space:]]*$(1)[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' $(DOCKERFILE) | head -n1
endef

PARTICLE_DOCKERFILE_VERSION      := $(strip $(shell $(call GET_COMMENT_KV,particle-dockerfile-version)))

# Use the parsed version unless the caller already set VERSION.
# Fallback to 'dev' if the syntax line is missing.
DOCKER_VERSION ?= $(if $(PARTICLE_DOCKERFILE_VERSION),$(PARTICLE_DOCKERFILE_VERSION),dev)

IMAGE_NAME           ?= tachyon-system-image-builder
IMAGE_TAG            ?= $(IMAGE_NAME):$(DOCKER_VERSION)
BASE_IMAGE           ?= ubuntu:22.04
UID                  ?= $(shell id -u 2>/dev/null || echo 1000)
GID                  ?= $(shell id -g 2>/dev/null || echo 1000)
PUSH_IMAGE           ?=
DOCKER_EXTRA_BUILD_ARGS ?=
export DOCKER_BUILDKIT ?= 1

STAMP_DIR            := .tmp/.build/docker
STAMP_NAME           := $(subst /,_,$(subst :,_,$(IMAGE_TAG)))
DOCKER_STAMP         := $(STAMP_DIR)/$(STAMP_NAME).stamp

.PHONY: docker docker/build docker/push docker/clean docker/rebuild

docker: docker/build

docker/build: $(DOCKER_STAMP)

# rule to build the docker image
$(DOCKER_STAMP): $(DOCKERFILE)
	@mkdir -p $(STAMP_DIR)
	@echo "==> Checking if Docker image $(IMAGE_TAG) exists locally..."
	@if docker image inspect "$(IMAGE_TAG)" >/dev/null 2>&1; then \
	  echo "Image $(IMAGE_TAG) already exists locally, skipping build"; \
	else \
	  echo "==> Trying to pull $(IMAGE_TAG)"; \
	  if echo "$(IMAGE_TAG)" | cut -d '/' -f1 | grep -q 'particle' && docker pull "$(IMAGE_TAG)"; then \
	    echo "Image $(IMAGE_TAG) pulled from registry"; \
	  else \
	    echo "==> Building Docker image $(IMAGE_TAG)"; \
	    docker build -t "$(IMAGE_TAG)" \
	      --load \
	      --file "$(DOCKERFILE)" \
	      --build-arg UID="$(UID)" \
	      --build-arg GID="$(GID)" \
	      --build-arg BASE_IMAGE="$(BASE_IMAGE)" \
	      $(DOCKER_EXTRA_BUILD_ARGS) \
	      "$(DOCKER_CONTEXT)"; \
	    if echo "$(IMAGE_TAG)" | cut -d '/' -f1 | grep -q 'particle' && [ -n "$(PUSH_IMAGE)" ]; then \
	      echo "==> Pushing image $(IMAGE_TAG)"; \
	      docker push "$(IMAGE_TAG)" || echo "Failed to push (docker login needed)"; \
	    else \
	      echo "PUSH_IMAGE not set, skipping push"; \
	    fi \
	  fi \
	fi
	@touch "$@"

docker/push: docker/build
	@echo "==> Pushing $(IMAGE_TAG)"
	@docker push "$(IMAGE_TAG)"

docker/clean:
	@echo "==> Cleaning Docker image and stamp"
	-@docker rmi -f "$(IMAGE_TAG)" >/dev/null 2>&1 || true
	-@rm -f "$(DOCKER_STAMP)"

docker/rebuild: docker/clean docker/build

.PHONY: docker/version
docker/version:
	@echo "Dockerfile syntax version: $(DOCKERFILE_SYNTAX_VERSION)"
	@echo "VERSION: $(DOCKER_VERSION)"
	@echo "IMAGE_TAG: $(IMAGE_TAG)"

# --- Docker run helpers -------------------------------------------------------

DOCKER_RUN := docker run --rm -it --privileged \
	-v $(PWD):/project \
	-v $(TMP_ROOT_DIR):/tmp/work \
	-v /dev:/dev \
	-w /project \
	$(IMAGE_TAG)

.PHONY: docker/shell
docker/shell: docker/build
	@echo "==> Starting interactive shell in $(IMAGE_TAG)"
	$(DOCKER_RUN) bash

##########################################################
# Host prerequisites
###########################################################

.PHONY: doctor
doctor:
	@echo "==> Checking minimal host prerequisites"
	@command -v docker >/dev/null 2>&1 || { echo "Error: Docker CLI not found. Please install Docker Desktop or Docker Engine."; exit 1; }
	@docker version >/dev/null 2>&1 || { echo "Error: Docker daemon not reachable (is Docker Desktop/daemon running, and do you have permission to use it?)."; exit 1; }
	@command -v git >/dev/null 2>&1 || { echo "Error: git not found. Please install git."; exit 1; }
	@echo "Host OK: docker and git are available."

##########################################################
# Main targets
###########################################################

# Version information
.PHONY: version
version:
	@echo "Tachyon System Image Composer v$(VERSION)"

# Clean temporary files
.PHONY: clean
clean:
	@echo "Cleaning temporary files..."
	@rm -rf $(DEFAULT_TMP_ROOT_DIR)
	@echo "Cleanup completed."

# Default target
.DEFAULT_GOAL := help
