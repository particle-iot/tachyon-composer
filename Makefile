####################################################################################################################
# Tachyon System Image Composer — 24.04 (new-BP / Quectel r108 / UEFI backend)
#
# `make build_24.04` orchestrates: fetch components (24.04 base rootfs, bp-fw, kernel deb,
# overlay tool + overlays) -> compose_24_04.sh (inside Docker) builds rootfs (+ overlay stack),
# efi, dtb, nonhlos, SIGNS the boot/firmware blobs (selectable key), and assembles an
# EDL-flashable image via ptool + partition_ext.
#
# This replaces the legacy 20.04 + U-Boot path: there is no 20.04 base zip, no U-Boot patch,
# and no qtestsign. Boot is XBL -> UEFI (from bp-fw) -> GRUB -> Linux.
#
# Version comes from the git tag (e.g. 1.2.0). The Dockerfile has its own version tag.
####################################################################################################################

# Helper variables
comma := ,

# Derive VERSION from the latest semantic tag in the repo
VERSION := $(shell \
  tag=$$(git describe --tags --abbrev=0 2>/dev/null || echo ""); \
  if echo "$$tag" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$'; then \
    echo $$tag; \
  elif [ -z "$$tag" ]; then \
    echo "Error: No version tag found. Please create one (e.g. git tag 1.2.0)" >&2; \
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
# DEBUG: true | false
DEBUG ?= false
INPUT_OVERLAY_DIR ?=
INPUT_OVERLAY_STACK ?=
OVERLAYS_REF ?= HEAD
ifneq ($(strip $(INPUT_OVERLAY_STACK)),)
	OVERLAYS_REF := $(INPUT_OVERLAY_STACK)
endif

# -------------------------------------------------------------------
# Authoritative source versions (always read from versions.json)
# -------------------------------------------------------------------
VERSIONS_FILE ?= versions.json
# Read sources.<repo>.<field>, the env block, and the signing block from versions.json.
# Strips `//` line-comments (lines starting with optional whitespace then //) before parsing,
# preserving `//` inside values like https:// URLs.
_SRC      = $(shell python3 -c "import json,re;t=re.sub(r'^\s*//.*$$','',open('$(VERSIONS_FILE)').read(),flags=re.MULTILINE);print(json.loads(t)['sources'].get('$(1)',{}).get('$(2)',''))" 2>/dev/null)
_ENV_JSON = $(shell python3 -c "import json,re;t=re.sub(r'^\s*//.*$$','',open('$(VERSIONS_FILE)').read(),flags=re.MULTILINE);e=json.loads(t).get('env',{});print(','.join(f'{k}={v}' for k,v in e.items()))" 2>/dev/null)
_SIGN     = $(shell python3 -c "import json,re;t=re.sub(r'^\s*//.*$$','',open('$(VERSIONS_FILE)').read(),flags=re.MULTILINE);print(json.loads(t).get('signing',{}).get('$(1)',''))" 2>/dev/null)

JSON_BASE24_PARAM       := $(call _SRC,particle-iot/tachyon-ubuntu-24.04,param)
JSON_OVERLAYS_PARAM     := $(call _SRC,particle-iot/tachyon-overlay,param)
JSON_OVERLAY_TOOL_PARAM := $(call _SRC,particle-iot/tachyon-overlay-tool,param)
ENV_FROM_JSON           := $(_ENV_JSON)

ifneq ($(strip $(JSON_BASE24_PARAM)),)
  INPUT_BASE_24_04_VERSION ?= $(JSON_BASE24_PARAM)
endif
ifneq ($(strip $(JSON_OVERLAYS_PARAM)),)
  override OVERLAYS_REF := $(JSON_OVERLAYS_PARAM)
endif
ifneq ($(strip $(ENV_FROM_JSON)),)
  INPUT_ENV ?= $(ENV_FROM_JSON)
endif

# -------------------------------------------------------------------
# Parameters (overridable)
# -------------------------------------------------------------------
COMMAND ?=
INPUT_REGION ?=                     # NA | RoW
INPUT_VARIANT ?=                    # headless | desktop  (headless == server)
INPUT_BASE_24_04_VERSION ?=         # e.g., 22-938ac1d
INPUT_ENV ?=
INPUT_OVERLAY_PATH ?= $(DEFAULT_OVERLAY_PATH)
OUTPUT_24_04_SYSTEM_IMAGE ?= $(DEFAULT_OUTPUT_PREFIX)-24.04-$(INPUT_REGION)-$(INPUT_VARIANT)-formfactor_dvt-$(OUTPUT_VERSION).zip

# Channel for the 24.04 base image (release | prerelease | preproduction)
BASE24_CHANNEL ?= release

# Working variables
TMP_ROOT_DIR ?= $(DEFAULT_TMP_ROOT_DIR)
TMP_INPUT_DIR ?= $(DEFAULT_TMP_INPUT_DIR)
TMP_OUTPUT_DIR ?= $(DEFAULT_TMP_OUTPUT_DIR)
INPUT_OVERLAY_DOCKER_PATH := $(strip /tmp/work/$(subst $(DEFAULT_TMP_ROOT_DIR)/,,$(INPUT_OVERLAY_PATH)))

# overlay stack defaults to ubuntu-<variant>-24.04 unless INPUT_OVERLAY_STACK is set
OVERLAY_STACK := $(if $(strip $(INPUT_OVERLAY_STACK)),$(INPUT_OVERLAY_STACK),ubuntu-$(INPUT_VARIANT)-24.04)

# -------------------------------------------------------------------
# Signing (composer-owned, selectable key). See scripts/signing/ and keys/.
# -------------------------------------------------------------------
SIGNING_PROFILE ?= $(if $(strip $(call _SIGN,profile)),$(call _SIGN,profile),test)
SIGNING_KEY     ?= $(call _SIGN,key)

# -------------------------------------------------------------------
# particle_image_v1 OTA format (@particle/tachyon-image)
# EMIT_FORMAT: factory (default) | ota-image | ota-boot ; EMIT_SLOT: a | b
# PARTICLE_IMAGE_LIB: path to the shared library repo (vendored into the image
# at build time as a tgz; the composer container runs its `particle-image` CLI).
# -------------------------------------------------------------------
EMIT_FORMAT        ?= factory
EMIT_SLOT          ?= a
PARTICLE_IMAGE_LIB ?= ../particle-tachyon-image
VENDOR_DIR         := $(TMP_ROOT_DIR)/vendor

# -------------------------------------------------------------------
# Validation helpers
# -------------------------------------------------------------------
define check_required_param
	@if [ -z "$($(1))" ]; then \
		echo "Error: $(1) parameter is required"; \
		echo "Usage: make build_24.04 VERSIONS_FILE=./versions.json INPUT_REGION=<NA|RoW> INPUT_VARIANT=<headless|desktop> [OUTPUT_VERSION=<x.y.z>]"; \
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

define validate_output_24_04
	@if [ -z "$(OUTPUT_24_04_SYSTEM_IMAGE)" ]; then \
		echo "Error: OUTPUT_24_04_SYSTEM_IMAGE not set and no default provided."; exit 1; fi
endef

# -------------------------------------------------------------------
# Derived filenames/URLs
# -------------------------------------------------------------------
# 24.04 base .img.xz / .img (rootfs source). Variant in {headless,desktop}, both published.
# Example: tachyon-ubuntu-24.04-headless-image-22-938ac1d.img.xz
BASE24_XZ_FILENAME := tachyon-ubuntu-24.04-$(INPUT_VARIANT)-image-$(INPUT_BASE_24_04_VERSION).img.xz
BASE24_URL := https://tachyon-ci.particle.io/$(BASE24_CHANNEL)/$(BASE24_XZ_FILENAME)
BASE24_XZ := $(TMP_INPUT_DIR)/$(BASE24_XZ_FILENAME)
BASE24_IMG := $(TMP_INPUT_DIR)/$(basename $(BASE24_XZ_FILENAME))
BASE24_IMG_BASENAME := $(notdir $(BASE24_IMG))

# bp-fw: referenced as an ARTIFACT ONLY (version + S3 url), never as a repo source.
# The BP firmware repo must not be a versions.json dependency; the composer consumes
# only its published release zip (S3 release, or a PR prerelease URL while testing the
# unsigned/nosign artifact). The zip carries bootbinaries, fw, and the pre-built
# region NON-HLOS images (nonhlos-em.img / nonhlos-na.img).
BP_FW_VERSION      := $(call _SRC,bp-fw,version)
BP_FW_URL          := $(call _SRC,bp-fw,url)
BOOTBINARIES_ZIP   := $(TMP_INPUT_DIR)/QCM6490_bootbinaries.zip

# kernel modules deb (single-sourced from versions.json) -> qcm6490-tachyon.dtb
KERNEL_TAG         := $(call _SRC,particle-iot/tachyon-ubuntu-24.04-kernel,param)
KERNEL_ABI         := $(call _SRC,particle-iot/tachyon-ubuntu-24.04-kernel,abi)
KERNEL_DEB_VERSION := $(call _SRC,particle-iot/tachyon-ubuntu-24.04-kernel,deb_version)
KERNEL_BASE_URL    := $(call _SRC,particle-iot/tachyon-ubuntu-24.04-kernel,base_url)
KERNEL_MODULES_DEB := linux-modules-6.8.0-$(KERNEL_ABI)-particle_$(KERNEL_DEB_VERSION)_arm64.deb
KERNEL_MODULES_URL := $(KERNEL_BASE_URL)/$(KERNEL_TAG)/$(subst +,%2B,$(KERNEL_MODULES_DEB))
KERNEL_DEB_FILE    := $(TMP_INPUT_DIR)/kernel/$(KERNEL_MODULES_DEB)

# region (NA|RoW) -> nonhlos firmware variant (na|em); image is shipped pre-built in the bp-fw artifact
NONHLOS_VARIANT := $(if $(filter NA,$(INPUT_REGION)),na,em)
NONHLOS_IMG     := $(TMP_INPUT_DIR)/nonhlos-$(NONHLOS_VARIANT).img

CURL_OPTS := -fL --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 30 -C -

# ------------------------------------------------------------
# Pretty header + resolved configuration printer
# ------------------------------------------------------------
CONFIG_SOURCE := versions.json: $(VERSIONS_FILE)

define PRINT_BANNER
	@printf '%s\n' \
	'**************************************************' \
	'*                                                *' \
	'*     Tachyon System Image (24.04 / new-BP)      *' \
	'*                                                *' \
	'**************************************************'
endef

define PRINT_CONFIG
	@echo "Source:            $(CONFIG_SOURCE)"
	@echo "Version Tag:       $(VERSION)"
	@echo
	@echo "Inputs (resolved)"
	@echo "  24.04 Build ID:  $(INPUT_BASE_24_04_VERSION)  ($(BASE24_IMG_BASENAME))"
	@echo "  Region:          $(INPUT_REGION)   (nonhlos: $(NONHLOS_VARIANT))"
	@echo "  Variant:         $(INPUT_VARIANT)"
	@echo "  bp-fw URL:       $(BP_FW_URL)"
	@echo "  Kernel:          $(KERNEL_TAG)  (abi $(KERNEL_ABI), deb $(KERNEL_DEB_VERSION))"
	@echo "  Overlay Stack:   $(OVERLAY_STACK)   (overlays ref: $(OVERLAYS_REF))"
	@echo "  Signing:         profile=$(SIGNING_PROFILE)  key=$(SIGNING_KEY)"
	@echo
	@echo "Output"
	@echo "  System Image:    $(OUTPUT_24_04_SYSTEM_IMAGE)"
	@echo "  Debug:           $(DEBUG)"
	@echo "  Input Env:       $(if $(strip $(INPUT_ENV)),$(INPUT_ENV),<none>)"
	@echo "**************************************************"
endef

.PHONY: print-config
print-config:
	$(PRINT_BANNER)
	$(PRINT_CONFIG)

# -------------------------------------------------------------------
# Help
# -------------------------------------------------------------------
.PHONY: help
help:
	@echo "Tachyon System Image Composer v$(VERSION) (24.04 / new-BP / UEFI)"
	@echo ""
	@echo "Available commands:"
	@echo "  build_24.04                 Build a Tachyon 24.04 EDL system image (new-BP)"
	@echo "  fetch_24_04 / _unxz         Download / decompress the 24.04 base .img.xz"
	@echo "  fetch_bp_fw                 Download bp-fw and split bootbinaries + fw zips"
	@echo "  fetch_kernel_deb            Download the kernel modules deb (for qcm6490-tachyon.dtb)"
	@echo "  fetch_overlay_tool          Clone tachyon-overlay-tool inside Docker"
	@echo "  fetch_tachyon_overlays      Clone tachyon-overlays inside Docker"
	@echo "  vendor_sectools             Refresh the committed sectoolsv2 signer in scripts/signing/sectools/ (~38MB)"
	@echo "  doctor / check_qemu / setup_qemu / clean"
	@echo ""
	@echo "Required parameters:"
	@echo "  INPUT_REGION                NA or RoW"
	@echo "  INPUT_VARIANT               headless (==server) or desktop"
	@echo ""
	@echo "Optional parameters:"
	@echo "  VERSIONS_FILE               Path to versions.json (default: versions.json)"
	@echo "  OUTPUT_VERSION              Version stamped into the image (default: $(DEFAULT_OUTPUT_VERSION))"
	@echo "  SIGNING_PROFILE             test | prod | none (default from versions.json signing.profile)"
	@echo "  SIGNING_KEY                 key name under ./keys/ (default from versions.json signing.key)"
	@echo "  INPUT_OVERLAY_DIR           Local overlays dir (skip cloning tachyon-overlays)"
	@echo "  INPUT_OVERLAY_STACK         Overlay stack/branch (e.g., ubuntu-headless-24.04)"
	@echo ""
	@echo "Examples:"
	@echo "  make build_24.04 VERSIONS_FILE=./versions.json INPUT_REGION=RoW INPUT_VARIANT=headless OUTPUT_VERSION=1.2.0"
	@echo ""

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
		if [ -f "$(notdir $@)" ]; then echo "$(notdir $@) exists, skipping"; exit 0; fi; \
		echo "==> Decompressing $(notdir $<)"; \
		xz -T0 -d -k -v "$(notdir $<)"; test -s "$(notdir $@)"; echo "Decompressed: $(notdir $@)"'

# -------------------------------------------------------------------
# Fetch: bp-fw artifact -> QCM6490_bootbinaries.zip + QCM6490_fw.zip
#                          + nonhlos-em.img / nonhlos-na.img (selected by region at compose)
# (point BP_FW_URL/versions.json at the feature/nosign PR prerelease to get sign-ready blobs
#  AND the pre-built NON-HLOS images)
# -------------------------------------------------------------------
.PHONY: fetch_bp_fw
fetch_bp_fw: $(BOOTBINARIES_ZIP)
$(BOOTBINARIES_ZIP): | docker/build
	@$(DOCKER_RUN) bash -lc 'set -euo pipefail; mkdir -p /tmp/work/input; cd /tmp/work/input; \
		Z="tachyon-bp-fw-$(BP_FW_VERSION).zip"; \
		if [ -s "$$Z" ]; then \
			echo "==> Reusing cached bp-fw download: $$Z"; \
		else \
			echo "==> Downloading bp-fw $(BP_FW_VERSION): $(BP_FW_URL)"; \
			curl $(CURL_OPTS) -o "$$Z" "$(BP_FW_URL)"; test -s "$$Z"; \
		fi; \
		rm -rf .bpfw && mkdir .bpfw && unzip -oq "$$Z" -d .bpfw; \
		test -d .bpfw/QCM6490_bootbinaries || { echo "ERROR: missing QCM6490_bootbinaries"; ls .bpfw; exit 1; }; \
		test -d .bpfw/QCM6490_fw          || { echo "ERROR: missing QCM6490_fw"; ls .bpfw; exit 1; }; \
		rm -f QCM6490_bootbinaries.zip QCM6490_fw.zip; \
		( cd .bpfw && zip -rq ../QCM6490_bootbinaries.zip QCM6490_bootbinaries && zip -rq ../QCM6490_fw.zip QCM6490_fw ); \
		rm -f nonhlos-em.img nonhlos-na.img; \
		if ls .bpfw/nonhlos-*.img >/dev/null 2>&1; then \
			cp .bpfw/nonhlos-*.img .; echo "OK: bp-fw split (+ $$(ls nonhlos-*.img | tr "\n" " "))"; \
		else \
			echo "WARNING: this bp-fw artifact has no nonhlos-*.img (predates NON-HLOS packaging)."; \
			echo "         The build will fail at compose stage 4 until versions.json points at a"; \
			echo "         bp-fw release that ships nonhlos-em.img / nonhlos-na.img."; \
			echo "OK: bp-fw split (no nonhlos images)"; \
		fi'

# -------------------------------------------------------------------
# Fetch: kernel modules deb (for qcm6490-tachyon.dtb)
# -------------------------------------------------------------------
.PHONY: fetch_kernel_deb
fetch_kernel_deb: $(KERNEL_DEB_FILE)
$(KERNEL_DEB_FILE): | docker/build
	@$(DOCKER_RUN) bash -lc 'set -euo pipefail; mkdir -p /tmp/work/input/kernel; cd /tmp/work/input/kernel; \
		echo "==> Downloading kernel deb: $(KERNEL_MODULES_URL)"; \
		curl $(CURL_OPTS) -o "$(KERNEL_MODULES_DEB)" "$(KERNEL_MODULES_URL)"; \
		test -s "$(KERNEL_MODULES_DEB)"; echo "OK: $(KERNEL_MODULES_DEB)"'

# -------------------------------------------------------------------
# Vendor the SECTOOLS signer into scripts/signing/sectools/ (host-side; ~59MB, gitignored)
# -------------------------------------------------------------------
.PHONY: vendor_sectools
vendor_sectools:
	@if [ ! -d scripts/signing/sectools ] || [ -z "$$(ls -A scripts/signing/sectools 2>/dev/null)" ]; then \
		echo "==> Vendoring SECTOOLS into scripts/signing/sectools"; \
		./scripts/signing/vendor-sectools.sh; \
	else \
		echo "SECTOOLS already vendored in scripts/signing/sectools"; \
	fi

# -------------------------------------------------------------------
# Fetch: tachyon-overlay-tool (clone inside Docker)
# -------------------------------------------------------------------
OVERLAY_TOOL_DIR      := /tmp/work/tools/tachyon-overlay-tool
OVERLAY_TOOL_CLONE_URL = https://github.com/particle-iot/tachyon-overlay-tool.git
# Ref comes from versions.json (sources -> particle-iot/tachyon-overlay-tool -> param),
# falling back to main. main carries the 'when' env-gate + ENV_* forwarding (PR #3 merged).
OVERLAY_TOOL_REF      ?= $(if $(strip $(JSON_OVERLAY_TOOL_PARAM)),$(JSON_OVERLAY_TOOL_PARAM),main)
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
# Fetch: tachyon-overlays (clone inside Docker, or use INPUT_OVERLAY_DIR)
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
# Build + pack the shared @particle/tachyon-image lib into .tmp/vendor/ as a tgz.
# compose_24_04.sh (section 6c) installs it inside the container and runs its CLI.
# Best-effort: if the lib repo is absent, the build still produces the legacy zip.
.PHONY: vendor_particle_image
vendor_particle_image:
	@if [ -d "$(PARTICLE_IMAGE_LIB)" ]; then \
		echo "Vendoring particle-image from $(PARTICLE_IMAGE_LIB) ..."; \
		mkdir -p "$(VENDOR_DIR)"; \
		rm -f "$(VENDOR_DIR)"/particle-tachyon-image-*.tgz; \
		( cd "$(PARTICLE_IMAGE_LIB)" && npm ci --silent && npm run build --silent \
			&& npm pack --silent --pack-destination "$(abspath $(VENDOR_DIR))" ) \
		&& echo "Vendored: $$(ls "$(VENDOR_DIR)"/particle-tachyon-image-*.tgz)"; \
	else \
		echo "NOTE: $(PARTICLE_IMAGE_LIB) not found; particle_image_v1 emission will be skipped"; \
	fi

.PHONY: build_24.04
build_24.04: version print-config check_qemu vendor_sectools vendor_particle_image fetch_24_04_unxz fetch_bp_fw fetch_kernel_deb fetch_overlay_tool fetch_tachyon_overlays docker/build
	@echo "Building Tachyon 24.04 (new-BP) System Image..."
	$(call check_required_param,INPUT_REGION)
	$(call check_required_param,INPUT_VARIANT)
	$(call check_required_param,INPUT_BASE_24_04_VERSION)
	$(call validate_region)
	$(call validate_variant)
	$(call validate_output_24_04)
	$(eval GENERATED_DISTRO_ENV := PKG_DISTRO_VERSION=$(OUTPUT_VERSION)$(comma)PKG_DISTRO_STACK=$(OVERLAY_STACK)$(comma)PKG_DISTRO_VARIANT=$(INPUT_VARIANT)$(comma)PKG_DISTRO_REGION=$(INPUT_REGION)$(comma)PKG_DISTRO_BOARD=formfactor_dvt$(comma)PKG_DISTRO_DISTRIBUTION=ubuntu$(comma)PKG_DISTRO_DISTRIBUTION_VERSION=24.04)
	$(eval GENERATED_SRC_ENV := PKG_SRC_TACHYON_COMPOSER=$(VERSION)$(comma)PKG_SRC_UBUNTU_24_04=$(INPUT_BASE_24_04_VERSION)$(comma)PKG_SRC_OVERLAYS=$(OVERLAYS_REF))
	$(eval GENERATED_ENV := $(GENERATED_DISTRO_ENV)$(comma)$(GENERATED_SRC_ENV))
	$(eval COMBINED_ENV := $(if $(strip $(INPUT_ENV)),$(INPUT_ENV)$(comma),)$(GENERATED_ENV))
	@mkdir -p $(TMP_INPUT_DIR) $(TMP_OUTPUT_DIR)
	@$(DOCKER_RUN) bash ./compose_24_04.sh \
		"$(BASE24_IMG_BASENAME)" \
		"$(OUTPUT_24_04_SYSTEM_IMAGE)" \
		"$(NONHLOS_VARIANT)" \
		"$(OVERLAY_STACK)" \
		"$(INPUT_OVERLAY_DOCKER_PATH)" \
		"$(COMBINED_ENV)" \
		"$(DEBUG)" \
		"$(SIGNING_PROFILE)" \
		"$(SIGNING_KEY)" \
		"$(EMIT_FORMAT)" \
		"$(EMIT_SLOT)"
	@echo ""
	@echo "Build completed successfully!"
	@echo "Output: $(abspath $(TMP_OUTPUT_DIR))/$(OUTPUT_24_04_SYSTEM_IMAGE)"

##########################################################
# Docker-related targets
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
PUSH_IMAGE           ?=
DOCKER_EXTRA_BUILD_ARGS ?=
export DOCKER_BUILDKIT ?= 1

STAMP_DIR            := .tmp/.build/docker
STAMP_NAME           := $(subst /,_,$(subst :,_,$(IMAGE_TAG)))
DOCKER_STAMP         := $(STAMP_DIR)/$(STAMP_NAME).stamp

.PHONY: docker docker/build docker/push docker/clean docker/rebuild docker/version docker/shell

docker: docker/build
docker/build: $(DOCKER_STAMP)

# Build (or pull) the builder image
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
	    docker build --network=host -t "$(IMAGE_TAG)" \
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
	    fi; \
	  fi; \
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

docker/version:
	@echo "Dockerfile version: $(DOCKER_VERSION)"
	@echo "IMAGE_TAG:          $(IMAGE_TAG)"

# --- Docker run helper --------------------------------------------------------
# In CI (env CI=true), drop -it to avoid "the input device is not a TTY"
DOCKER_TTY := $(if $(CI),, -it)

DOCKER_RUN := docker run --network=host --rm $(DOCKER_TTY) --privileged \
	-v $(PWD):/project \
	-v $(TMP_ROOT_DIR):/tmp/work \
	-v /dev:/dev \
	-w /project \
	$(IMAGE_TAG)

docker/shell: docker/build
	@echo "==> Starting interactive shell in $(IMAGE_TAG)"
	$(DOCKER_RUN) bash

##########################################################
# Host prerequisites
##########################################################
.PHONY: doctor check_qemu setup_qemu
doctor:
	@echo "==> Checking minimal host prerequisites"
	@command -v docker >/dev/null 2>&1 || { echo "Error: Docker CLI not found."; exit 1; }
	@docker version >/dev/null 2>&1 || { echo "Error: Docker daemon not reachable."; exit 1; }
	@command -v git >/dev/null 2>&1 || { echo "Error: git not found."; exit 1; }
	@echo "Host OK: docker and git are available."
	@$(MAKE) check_qemu

check_qemu:
	@HOST_ARCH=$$(uname -m); HOST_OS=$$(uname -s); \
	if { [ "$$HOST_ARCH" = "x86_64" ] || [ "$$HOST_ARCH" = "amd64" ]; } && [ "$$HOST_OS" = "Linux" ]; then \
		if [ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then \
			echo "==> Registering QEMU arm64 emulation for x86_64 Linux host"; \
			docker run --rm --privileged multiarch/qemu-user-static --reset -p yes; \
			[ -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || { echo "ERROR: QEMU setup failed"; exit 1; }; \
		fi; \
	fi

setup_qemu:
	@echo "==> Setting up QEMU user-mode emulation"
	@HOST_ARCH=$$(uname -m); \
	if [ "$$HOST_ARCH" = "x86_64" ] || [ "$$HOST_ARCH" = "amd64" ]; then \
		docker run --rm --privileged multiarch/qemu-user-static --reset -p yes; \
		echo "QEMU setup complete"; \
	else \
		echo "Not needed on $$HOST_ARCH architecture"; \
	fi

##########################################################
# Misc
##########################################################
.PHONY: version clean
version:
	@echo "Tachyon System Image Composer v$(VERSION)"

clean:
	@echo "Cleaning temporary files..."
	@rm -rf $(DEFAULT_TMP_ROOT_DIR)
	@# Sweep stray CI-log downloads that land in the repo root as
	@# "N_build (REGION, VARIANT).txt" files and "build (REGION, VARIANT)/" dirs.
	@rm -rf ./*"_build ("*").txt" "./build ("*")" 2>/dev/null || true
	@echo "Cleanup completed."

.DEFAULT_GOAL := help
