####################################################################################################################
# Tachyon System Image Composer — 24.04 (new-BP / Quectel r108 / UEFI backend)
#
# `make build_24.04` orchestrates: fetch components (24.04 base rootfs, bp-fw 2.0.0,
# kernel deb, overlay tool + overlays) -> compose_24_04.sh inside Docker builds the
# rootfs (+ overlay stack), efi, dtb, nonhlos and assembles an EDL-flashable image
# via ptool + partition_ext.
#
# Version comes from the git tag (e.g. 0.1.0). The Dockerfile has its own version tag.
####################################################################################################################

comma := ,

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
DEFAULT_OUTPUT_VERSION := 9.9.999
DEFAULT_OVERLAY_PATH := input/tachyon-overlays

# optional parameters
OUTPUT_VERSION ?= $(DEFAULT_OUTPUT_VERSION)
DEBUG ?= false                       # true | false
VERSIONS_FILE ?=
INPUT_OVERLAY_DIR ?=
INPUT_OVERLAY_STACK ?=
OVERLAYS_REF ?= HEAD
ifneq ($(strip $(INPUT_OVERLAY_STACK)),)
	OVERLAYS_REF := $(INPUT_OVERLAY_STACK)
endif

# Authoritative source versions (always read from versions.json for the new-BP path)
VERSIONS_FILE ?= versions.json
_SRC = $(shell python3 -c "import json;print(json.load(open('$(VERSIONS_FILE)'))['sources'].get('$(1)',{}).get('$(2)',''))" 2>/dev/null)
_ENV_JSON = $(shell python3 -c "import json;e=json.load(open('$(VERSIONS_FILE)')).get('env',{});print(','.join(f'{k}={v}' for k,v in e.items()))" 2>/dev/null)

JSON_BASE24_PARAM := $(call _SRC,particle-iot/tachyon-ubuntu-24.04,param)
JSON_OVERLAYS_PARAM := $(call _SRC,particle-iot/tachyon-overlay,param)
ENV_FROM_JSON := $(_ENV_JSON)

ifneq ($(strip $(JSON_BASE24_PARAM)),)
  INPUT_BASE_24_04_VERSION ?= $(JSON_BASE24_PARAM)
endif
ifneq ($(strip $(JSON_OVERLAYS_PARAM)),)
  override OVERLAYS_REF := $(JSON_OVERLAYS_PARAM)
endif
ifneq ($(strip $(ENV_FROM_JSON)),)
  INPUT_ENV ?= $(ENV_FROM_JSON)
endif

# Parameters (overridable)
COMMAND ?=
INPUT_REGION ?=                     # NA | RoW
INPUT_VARIANT ?=                    # headless | desktop
INPUT_BASE_24_04_VERSION ?=         # e.g., 21-4d6898e
INPUT_ENV ?=
INPUT_OVERLAY_PATH ?= $(DEFAULT_OVERLAY_PATH)
OUTPUT_24_04_SYSTEM_IMAGE ?= $(DEFAULT_OUTPUT_PREFIX)-24.04-$(INPUT_REGION)-$(INPUT_VARIANT)-formfactor_dvt-$(OUTPUT_VERSION).zip

# Working variables
TMP_ROOT_DIR ?= $(DEFAULT_TMP_ROOT_DIR)
TMP_INPUT_DIR ?= $(DEFAULT_TMP_INPUT_DIR)
TMP_OUTPUT_DIR ?= $(DEFAULT_TMP_OUTPUT_DIR)
INPUT_OVERLAY_DOCKER_PATH := $(strip /tmp/work/$(subst $(DEFAULT_TMP_ROOT_DIR)/,,$(INPUT_OVERLAY_PATH)))

# overlay stack defaults to ubuntu-<variant>-24.04 unless INPUT_OVERLAY_STACK is set
OVERLAY_STACK := $(if $(strip $(INPUT_OVERLAY_STACK)),$(INPUT_OVERLAY_STACK),ubuntu-$(INPUT_VARIANT)-24.04)

# -------------------------------------------------------------------
# Validation helpers
# -------------------------------------------------------------------
define check_required_param
	@if [ -z "$($(1))" ]; then \
		echo "Error: $(1) parameter is required"; \
		exit 1; \
	fi
endef

define validate_region
	@if [ "$(INPUT_REGION)" != "NA" ] && [ "$(INPUT_REGION)" != "RoW" ]; then \
		echo "Error: INPUT_REGION must be 'NA' or 'RoW', got '$(INPUT_REGION)'"; exit 1; fi
endef

define validate_variant
	@if [ "$(INPUT_VARIANT)" != "headless" ] && [ "$(INPUT_VARIANT)" != "desktop" ]; then \
		echo "Error: INPUT_VARIANT must be 'headless' or 'desktop', got '$(INPUT_VARIANT)'"; exit 1; fi
endef

# -------------------------------------------------------------------
# Derived filenames/URLs
# -------------------------------------------------------------------
# 24.04 base .img.xz / .img (rootfs source)
BASE24_XZ_FILENAME := tachyon-ubuntu-24.04-$(INPUT_VARIANT)-image-$(INPUT_BASE_24_04_VERSION).img.xz
BASE24_URL := https://tachyon-ci.particle.io/release/$(BASE24_XZ_FILENAME)
BASE24_XZ := $(TMP_INPUT_DIR)/$(BASE24_XZ_FILENAME)
BASE24_IMG := $(TMP_INPUT_DIR)/$(basename $(BASE24_XZ_FILENAME))
BASE24_IMG_BASENAME := $(notdir $(BASE24_IMG))

# bp-fw 2.0.0 (S3 permanent release) -> bootbinaries + fw
BP_FW_URL          := $(call _SRC,particle-iot-inc/tachyon-quectel-bp-fw-sdk-r108,url)
BOOTBINARIES_ZIP   := $(TMP_INPUT_DIR)/QCM6490_bootbinaries.zip

# kernel modules deb (S3 permanent release) -> qcm6490-tachyon.dtb
KERNEL_TAG         := $(call _SRC,particle-iot/tachyon-ubuntu-24.04-kernel,param)
KERNEL_ABI         := $(call _SRC,particle-iot/tachyon-ubuntu-24.04-kernel,abi)
KERNEL_DEB_VERSION := $(call _SRC,particle-iot/tachyon-ubuntu-24.04-kernel,deb_version)
KERNEL_BASE_URL    := $(call _SRC,particle-iot/tachyon-ubuntu-24.04-kernel,base_url)
KERNEL_MODULES_DEB := linux-modules-6.8.0-$(KERNEL_ABI)-particle_$(KERNEL_DEB_VERSION)_arm64.deb
KERNEL_MODULES_URL := $(KERNEL_BASE_URL)/$(KERNEL_TAG)/$(subst +,%2B,$(KERNEL_MODULES_DEB))
KERNEL_DEB_FILE    := $(TMP_INPUT_DIR)/kernel/$(KERNEL_MODULES_DEB)

# region (NA|RoW) -> nonhlos firmware variant (na|em)
NONHLOS_VARIANT := $(if $(filter NA,$(INPUT_REGION)),na,em)

CURL_OPTS := -fL --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 30 -C -

# ------------------------------------------------------------
# Config printer
# ------------------------------------------------------------
.PHONY: print-config
print-config:
	@echo "Version Tag:    $(VERSION)"
	@echo "Region:         $(INPUT_REGION)   Variant: $(INPUT_VARIANT)   nonhlos: $(NONHLOS_VARIANT)"
	@echo "24.04 base:     $(INPUT_BASE_24_04_VERSION)  ($(BASE24_IMG_BASENAME))"
	@echo "bp-fw:          $(BP_FW_URL)"
	@echo "kernel:         $(KERNEL_TAG)"
	@echo "overlay stack:  $(OVERLAY_STACK)  (overlays ref: $(OVERLAYS_REF))"
	@echo "env:            $(if $(strip $(INPUT_ENV)),$(INPUT_ENV),<none>)"
	@echo "output:         $(OUTPUT_24_04_SYSTEM_IMAGE)"

# -------------------------------------------------------------------
# Help
# -------------------------------------------------------------------
.PHONY: help
help:
	@echo "Tachyon System Image Composer v$(VERSION) (new-BP / UEFI)"
	@echo ""
	@echo "  make build_24.04 VERSIONS_FILE=./versions.json INPUT_REGION=RoW INPUT_VARIANT=headless"
	@echo ""
	@echo "Targets: build_24.04 | fetch_24_04(_unxz) | fetch_bp_fw | fetch_kernel_deb |"
	@echo "         fetch_overlay_tool | fetch_tachyon_overlays | doctor | check_qemu | clean"

# -------------------------------------------------------------------
# Fetch: 24.04 base rootfs image
# -------------------------------------------------------------------
.PHONY: fetch_24_04 fetch_24_04_unxz
fetch_24_04: $(BASE24_XZ)
$(BASE24_XZ): | docker/build
	$(call check_required_param,INPUT_BASE_24_04_VERSION)
	$(call check_required_param,INPUT_VARIANT)
	$(call validate_variant)
	@$(DOCKER_RUN) bash -lc 'set -euo pipefail; mkdir -p "$(TMP_INPUT_DIR)"; \
		echo "==> Downloading 24.04 base: $(BASE24_URL)"; \
		curl $(CURL_OPTS) -o "$@" "$(BASE24_URL)"; test -s "$@"; echo "Downloaded: $@"'

fetch_24_04_unxz: $(BASE24_IMG)
$(BASE24_IMG): $(BASE24_XZ) | docker/build
	@$(DOCKER_RUN) bash -lc 'set -euo pipefail; cd "$(TMP_INPUT_DIR)"; \
		echo "==> Decompressing $(notdir $<)"; \
		xz -T0 -d -k -v "$(notdir $<)"; test -s "$(notdir $@)"; echo "Decompressed: $(notdir $@)"'

# -------------------------------------------------------------------
# Fetch: bp-fw 2.0.0 (S3 permanent release) -> bootbinaries + fw zips
# -------------------------------------------------------------------
.PHONY: fetch_bp_fw
fetch_bp_fw: $(BOOTBINARIES_ZIP)
$(BOOTBINARIES_ZIP): | docker/build
	@$(DOCKER_RUN) bash -lc 'set -euo pipefail; mkdir -p /tmp/work/input; cd /tmp/work/input; \
		echo "==> Downloading bp-fw: $(BP_FW_URL)"; \
		curl $(CURL_OPTS) -o tachyon-bp-fw.zip "$(BP_FW_URL)"; test -s tachyon-bp-fw.zip; \
		rm -rf .bpfw && mkdir .bpfw && unzip -oq tachyon-bp-fw.zip -d .bpfw; \
		test -d .bpfw/QCM6490_bootbinaries || { echo "ERROR: missing QCM6490_bootbinaries"; ls .bpfw; exit 1; }; \
		test -d .bpfw/QCM6490_fw          || { echo "ERROR: missing QCM6490_fw"; ls .bpfw; exit 1; }; \
		rm -f QCM6490_bootbinaries.zip QCM6490_fw.zip; \
		( cd .bpfw && zip -rq ../QCM6490_bootbinaries.zip QCM6490_bootbinaries && zip -rq ../QCM6490_fw.zip QCM6490_fw ); \
		echo "OK: bp-fw split"'

# -------------------------------------------------------------------
# Fetch: kernel modules deb (S3 permanent release) for qcm6490-tachyon.dtb
# -------------------------------------------------------------------
.PHONY: fetch_kernel_deb
fetch_kernel_deb: $(KERNEL_DEB_FILE)
$(KERNEL_DEB_FILE): | docker/build
	@$(DOCKER_RUN) bash -lc 'set -euo pipefail; mkdir -p /tmp/work/input/kernel; cd /tmp/work/input/kernel; \
		echo "==> Downloading kernel deb: $(KERNEL_MODULES_URL)"; \
		curl $(CURL_OPTS) -o "$(KERNEL_MODULES_DEB)" "$(KERNEL_MODULES_URL)"; \
		test -s "$(KERNEL_MODULES_DEB)"; echo "OK: $(KERNEL_MODULES_DEB)"'

# -------------------------------------------------------------------
# Fetch: tachyon-overlay-tool (clone inside Docker)
# -------------------------------------------------------------------
OVERLAY_TOOL_DIR      := /tmp/work/tools/tachyon-overlay-tool
OVERLAY_TOOL_CLONE_URL = https://github.com/particle-iot/tachyon-overlay-tool.git
OVERLAY_TOOL_REF      ?= main
OVERLAY_TOOL_STAMP    := $(OVERLAY_TOOL_DIR)/.installed

.PHONY: fetch_overlay_tool
fetch_overlay_tool: $(OVERLAY_TOOL_STAMP)
$(OVERLAY_TOOL_STAMP): | docker/build
	@echo "==> Setting up tachyon-overlay-tool inside Docker"
	@mkdir -p "$(OVERLAY_TOOL_DIR)"
	@$(DOCKER_RUN) bash -lc 'set -euo pipefail; \
		if [ ! -d "$(OVERLAY_TOOL_DIR)/.git" ]; then \
			git clone --depth 1 "$(OVERLAY_TOOL_CLONE_URL)" "$(OVERLAY_TOOL_DIR)"; \
		fi; \
		git -C "$(OVERLAY_TOOL_DIR)" fetch --depth 1 origin "$(OVERLAY_TOOL_REF)"; \
		git -C "$(OVERLAY_TOOL_DIR)" checkout -q FETCH_HEAD; \
		if [ -f "$(OVERLAY_TOOL_DIR)/requirements.txt" ]; then \
			pip3 install --user --no-cache-dir -r "$(OVERLAY_TOOL_DIR)/requirements.txt" || \
			  sudo pip3 install --break-system-packages --no-cache-dir -r "$(OVERLAY_TOOL_DIR)/requirements.txt"; \
		fi; \
		{ test -f "$(OVERLAY_TOOL_DIR)/overlay.py" && test -f "$(OVERLAY_TOOL_DIR)/run-overlay.sh"; } \
		  || { echo "Error: overlay.py / run-overlay.sh missing"; exit 1; }; \
		touch "$(OVERLAY_TOOL_DIR)/.installed"'

# -------------------------------------------------------------------
# Fetch: tachyon-overlays (clone inside Docker)
# -------------------------------------------------------------------
OVERLAYS_REPO_DIR := $(INPUT_OVERLAY_DOCKER_PATH)

.PHONY: fetch_tachyon_overlays
fetch_tachyon_overlays: | docker/build
	@if [ -n "$(INPUT_OVERLAY_DIR)" ]; then \
		echo "Using local overlays from $(INPUT_OVERLAY_DIR)"; \
		rm -rf $(TMP_ROOT_DIR)/input/tachyon-overlays; mkdir -p $(TMP_ROOT_DIR)/input/tachyon-overlays; \
		cp -r "$(INPUT_OVERLAY_DIR)/." $(TMP_ROOT_DIR)/input/tachyon-overlays/; \
	else \
		echo "==> Fetching tachyon-overlays into $(INPUT_OVERLAY_DOCKER_PATH)"; \
		$(DOCKER_RUN) bash -lc 'set -euo pipefail; \
			mkdir -p "$(dir $(OVERLAYS_REPO_DIR))"; \
			if [ ! -d "$(OVERLAYS_REPO_DIR)/.git" ]; then \
				git clone --depth 1 https://github.com/particle-iot/tachyon-overlays.git "$(OVERLAYS_REPO_DIR)"; \
			fi; \
			if [ "$(OVERLAYS_REF)" != "HEAD" ]; then \
				git -C "$(OVERLAYS_REPO_DIR)" fetch --depth 1 origin "$(OVERLAYS_REF)"; \
				git -C "$(OVERLAYS_REPO_DIR)" checkout -q FETCH_HEAD; \
			fi'; \
	fi

# -------------------------------------------------------------------
# Main build
# -------------------------------------------------------------------
.PHONY: build_24.04
build_24.04: version print-config check_qemu fetch_24_04_unxz fetch_bp_fw fetch_kernel_deb fetch_overlay_tool fetch_tachyon_overlays docker/build
	@echo "Building Tachyon 24.04 (new-BP) System Image..."
	$(call check_required_param,INPUT_REGION)
	$(call check_required_param,INPUT_VARIANT)
	$(call check_required_param,INPUT_BASE_24_04_VERSION)
	$(call validate_region)
	$(call validate_variant)
	$(eval GENERATED_ENV := PKG_DISTRO_VERSION=$(OUTPUT_VERSION)$(comma)PKG_DISTRO_STACK=$(OVERLAY_STACK)$(comma)PKG_DISTRO_VARIANT=$(INPUT_VARIANT)$(comma)PKG_DISTRO_REGION=$(INPUT_REGION)$(comma)PKG_DISTRO_BOARD=formfactor_dvt$(comma)PKG_DISTRO_DISTRIBUTION=ubuntu$(comma)PKG_DISTRO_DISTRIBUTION_VERSION=24.04$(comma)PKG_SRC_TACHYON_COMPOSER=$(VERSION)$(comma)PKG_SRC_UBUNTU_24_04=$(INPUT_BASE_24_04_VERSION))
	$(eval COMBINED_ENV := $(if $(strip $(INPUT_ENV)),$(INPUT_ENV)$(comma),)$(GENERATED_ENV))
	@mkdir -p $(TMP_INPUT_DIR) $(TMP_OUTPUT_DIR)
	@$(DOCKER_RUN) bash ./compose_24_04.sh \
		"$(BASE24_IMG_BASENAME)" \
		"$(OUTPUT_24_04_SYSTEM_IMAGE)" \
		"$(NONHLOS_VARIANT)" \
		"$(OVERLAY_STACK)" \
		"$(INPUT_OVERLAY_DOCKER_PATH)" \
		"$(COMBINED_ENV)" \
		"$(DEBUG)"
	@echo "Output: $(abspath $(TMP_OUTPUT_DIR))/$(OUTPUT_24_04_SYSTEM_IMAGE)"

##########################################################
# Docker
##########################################################
DOCKERFILE           ?= Dockerfile
DOCKER_CONTEXT       ?= .

define GET_COMMENT_KV
sed -nE 's/^[[:space:]]*#[[:space:]]*$(1)[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' $(DOCKERFILE) | head -n1
endef
PARTICLE_DOCKERFILE_VERSION := $(strip $(shell $(call GET_COMMENT_KV,particle-dockerfile-version)))
DOCKER_VERSION ?= $(if $(PARTICLE_DOCKERFILE_VERSION),$(PARTICLE_DOCKERFILE_VERSION),dev)

IMAGE_NAME           ?= tachyon-system-image-builder
IMAGE_TAG            ?= $(IMAGE_NAME):$(DOCKER_VERSION)
BASE_IMAGE           ?= ubuntu:24.04
UID                  ?= $(shell id -u 2>/dev/null || echo 1000)
GID                  ?= $(shell id -g 2>/dev/null || echo 1000)
export DOCKER_BUILDKIT ?= 1

STAMP_DIR            := .tmp/.build/docker
STAMP_NAME           := $(subst /,_,$(subst :,_,$(IMAGE_TAG)))
DOCKER_STAMP         := $(STAMP_DIR)/$(STAMP_NAME).stamp

.PHONY: docker docker/build docker/clean docker/rebuild docker/shell
docker: docker/build
docker/build: $(DOCKER_STAMP)

$(DOCKER_STAMP): $(DOCKERFILE)
	@mkdir -p $(STAMP_DIR)
	@if docker image inspect "$(IMAGE_TAG)" >/dev/null 2>&1; then \
	  echo "Image $(IMAGE_TAG) already exists, skipping build"; \
	else \
	  echo "==> Building Docker image $(IMAGE_TAG)"; \
	  docker build --network=host -t "$(IMAGE_TAG)" --load --file "$(DOCKERFILE)" \
	    --build-arg UID="$(UID)" --build-arg GID="$(GID)" --build-arg BASE_IMAGE="$(BASE_IMAGE)" \
	    "$(DOCKER_CONTEXT)"; \
	fi
	@touch "$@"

docker/clean:
	-@docker rmi -f "$(IMAGE_TAG)" >/dev/null 2>&1 || true
	-@rm -f "$(DOCKER_STAMP)"
docker/rebuild: docker/clean docker/build

# In CI (env CI=true), drop -it to avoid "the input device is not a TTY"
DOCKER_TTY := $(if $(CI),, -it)
DOCKER_RUN := docker run --network=host --rm $(DOCKER_TTY) --privileged \
	-v $(PWD):/project \
	-v $(TMP_ROOT_DIR):/tmp/work \
	-v /dev:/dev \
	-w /project \
	$(IMAGE_TAG)

docker/shell: docker/build
	$(DOCKER_RUN) bash

##########################################################
# Host prerequisites
##########################################################
.PHONY: doctor check_qemu setup_qemu
doctor:
	@command -v docker >/dev/null 2>&1 || { echo "Error: Docker not found."; exit 1; }
	@docker version >/dev/null 2>&1 || { echo "Error: Docker daemon not reachable."; exit 1; }
	@command -v git >/dev/null 2>&1 || { echo "Error: git not found."; exit 1; }
	@echo "Host OK: docker and git available."
	@$(MAKE) check_qemu

check_qemu:
	@HOST_ARCH=$$(uname -m); HOST_OS=$$(uname -s); \
	if { [ "$$HOST_ARCH" = "x86_64" ] || [ "$$HOST_ARCH" = "amd64" ]; } && [ "$$HOST_OS" = "Linux" ]; then \
		if [ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then \
			echo "==> Registering QEMU arm64 emulation"; \
			docker run --rm --privileged multiarch/qemu-user-static --reset -p yes; \
			[ -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || { echo "ERROR: QEMU setup failed"; exit 1; }; \
		fi; \
	fi

setup_qemu:
	@docker run --rm --privileged multiarch/qemu-user-static --reset -p yes

##########################################################
# Misc
##########################################################
.PHONY: version clean
version:
	@echo "Tachyon System Image Composer v$(VERSION)"

clean:
	@echo "Cleaning temporary files..."
	@rm -rf $(DEFAULT_TMP_ROOT_DIR)
	@echo "Cleanup completed."

.DEFAULT_GOAL := help
