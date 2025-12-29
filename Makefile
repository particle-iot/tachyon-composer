####################################################################################################################
# Tachyon System Image Composer
# Version comes from the tag in git, e.g., v0.1.0 -> 0.1.0
#
# Notes:
#  - the dockerfile is cached. There is a version tag in the top of the file that should be updated with each release.
####################################################################################################################

# Helper variables
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
INPUT_UBOOT_DIR ?=
INPUT_OVERLAY_DIR ?=
INPUT_OVERLAY_STACK ?=
OVERLAYS_REF ?= HEAD
ifneq ($(strip $(INPUT_OVERLAY_STACK)),)
	OVERLAYS_REF := $(INPUT_OVERLAY_STACK)
endif

ifdef VERSIONS_FILE
  $(info Using versions file $(VERSIONS_FILE) to override versions)

  JSON_UBOOT_PARAM := $(shell python3 -c "import json,sys; j=json.load(open(sys.argv[1])); print(j.get('sources',{}).get('particle-iot/tachyon-u-boot',{}).get('param',''))" $(VERSIONS_FILE))
  JSON_BASE20_PARAM := $(shell python3 -c "import json,sys; j=json.load(open(sys.argv[1])); print(j.get('sources',{}).get('particle-iot-inc/tachyon-release-builder',{}).get('param',''))" $(VERSIONS_FILE))
  JSON_BASE24_PARAM := $(shell python3 -c "import json,sys; j=json.load(open(sys.argv[1])); print(j.get('sources',{}).get('particle-iot/tachyon-ubuntu-24.04',{}).get('param',''))" $(VERSIONS_FILE))
  JSON_KERNEL_PARAM := $(shell python3 -c "import json,sys; j=json.load(open(sys.argv[1])); print(j.get('sources',{}).get('particle-iot/tachyon-ubuntu-24.04-kernel',{}).get('param',''))" $(VERSIONS_FILE))
  JSON_OVERLAYS_PARAM := $(shell python3 -c "import json,sys; j=json.load(open(sys.argv[1])); s=j.get('sources',{}); o=s.get('particle-iot/tachyon-overlay') or s.get('particle-iot/tachyon-overlays',{}); print((o or {}).get('param',''))" $(VERSIONS_FILE))

  # unified env (preferred); legacy fallback to packages->PKG_* if env missing
  ENV_FROM_JSON := $(shell python3 -c "import json,sys; d=json.load(open(sys.argv[1])); e=d.get('env',{}); e = e or ({('PKG_'+k.replace('-','_')):v for k,v in d.get('packages',{}).items()} if (not e and d.get('packages')) else {}); print(','.join([f'{k}={v}' for k,v in e.items()]))" $(VERSIONS_FILE))

  ifneq ($(strip $(JSON_BASE20_PARAM)),)
    override INPUT_BASE_20_04_VERSION := $(JSON_BASE20_PARAM)
  endif
  ifneq ($(strip $(JSON_UBOOT_PARAM)),)
    override INPUT_UBOOT_VERSION := $(JSON_UBOOT_PARAM)
  endif
  ifneq ($(strip $(JSON_BASE24_PARAM)),)
    override INPUT_BASE_24_04_VERSION := $(JSON_BASE24_PARAM)
  endif
  ifneq ($(strip $(JSON_KERNEL_PARAM)),)
    override INPUT_KERNEL_VERSION := $(JSON_KERNEL_PARAM)
  endif
  ifneq ($(strip $(JSON_OVERLAYS_PARAM)),)
    override OVERLAYS_REF := $(JSON_OVERLAYS_PARAM)
  endif
  ifneq ($(strip $(ENV_FROM_JSON)),)
    override INPUT_ENV_VARS := $(ENV_FROM_JSON)
    override INPUT_ENV := $(ENV_FROM_JSON)
  endif
endif

# Parameters (overridable)
COMMAND ?=
INPUT_BASE_20_04_VERSION ?=         # semver, e.g., 1.0.167
INPUT_REGION ?=                     # NA | RoW
INPUT_VARIANT ?=                    # headless | desktop
INPUT_UBOOT_VERSION ?=              # semver, e.g., 1.0.3
INPUT_BASE_24_04_VERSION ?=         # e.g., 14-276cd6b
INPUT_ENV	?=                      	# optional, e.g., "VAR1=val1,VAR2=val2"
INPUT_OVERLAY_PATH ?= $(DEFAULT_OVERLAY_PATH) # optional, path to overlay dir (inside container, e.g., ./os_overlays/24.04)
OUTPUT_24_04_SYSTEM_IMAGE ?= $(DEFAULT_OUTPUT_PREFIX)-24.04-$(INPUT_REGION)-$(INPUT_VARIANT)-formfactor_dvt-$(OUTPUT_VERSION).zip

# Working variables
TMP_ROOT_DIR ?= $(DEFAULT_TMP_ROOT_DIR)
TMP_INPUT_DIR ?= $(DEFAULT_TMP_INPUT_DIR)
TMP_OUTPUT_DIR ?= $(DEFAULT_TMP_OUTPUT_DIR)
BUILD_SCRIPT := $(TMP_INPUT_DIR)/build_24.04.sh
INPUT_OVERLAY_DOCKER_PATH := $(strip /tmp/work/$(subst $(DEFAULT_TMP_ROOT_DIR)/,,$(INPUT_OVERLAY_PATH)))

#default INPUT_ENV to INPUT_ENV_VARS if set
ifneq ($(strip $(INPUT_ENV_VARS)),)
	INPUT_ENV := $(strip $(INPUT_ENV_VARS))
endif

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
UBOOT_URL_PRIMARY := https://linux-dist.particle.io/prerelease/$(UBOOT_FILENAME)
UBOOT_URL_ENCODED := https://linux-dist.particle.io/prerelease%2F$(UBOOT_FILENAME)
UBOOT_ZIP := $(TMP_INPUT_DIR)/$(UBOOT_FILENAME)
UBOOT_DIR := u-boot

# 24.04 base .img.xz and .img (variant + "build-id" fragment)
# Example: tachyon-ubuntu-24.04-headless-image-14-276cd6b.img.xz
BASE24_XZ_FILENAME := tachyon-ubuntu-24.04-$(INPUT_VARIANT)-image-$(INPUT_BASE_24_04_VERSION).img.xz
BASE24_URL := https://tachyon-ci.particle.io/release/$(BASE24_XZ_FILENAME)
BASE24_XZ := $(TMP_INPUT_DIR)/$(BASE24_XZ_FILENAME)
BASE24_IMG := $(TMP_INPUT_DIR)/$(basename $(BASE24_XZ_FILENAME))
BASE24_SYSTEM_IMAGE_DIR := sys-img-24.04

# ------------------------------------------------------------
# Pretty header + resolved configuration printer
# ------------------------------------------------------------

CONFIG_SOURCE := $(if $(strip $(VERSIONS_FILE)),versions.json: $(VERSIONS_FILE),CLI args)

define PRINT_BANNER
	@printf '%s\n' \
	'**************************************************' \
	'*                                                *' \
	'*        Tachyon System Image — Configuration    *' \
	'*                                                *' \
	'**************************************************'
endef

define PRINT_CONFIG
	@echo "Source:            $(CONFIG_SOURCE)"
	@echo "Version Tag:       $(VERSION)"
	@echo
	@echo "Inputs (resolved)"
	@echo "  Base 20.04 Ver:  $(INPUT_BASE_20_04_VERSION)"
	@echo "  24.04 Build ID:  $(INPUT_BASE_24_04_VERSION)"
	@echo "  Region:          $(INPUT_REGION)"
	@echo "  Variant:         $(INPUT_VARIANT)"
	@echo "  U-Boot Ver:      $(if $(INPUT_UBOOT_VERSION),$(INPUT_UBOOT_VERSION),<using INPUT_UBOOT_DIR>)"
	@echo "  Overlays Ref:    $(OVERLAYS_REF)"
	@echo
	@echo "Paths"
	@echo "  Tmp Input Dir:   $(TMP_INPUT_DIR)"
	@echo "  Tmp Output Dir:  $(TMP_OUTPUT_DIR)"
	@echo "  Overlay Path:    $(INPUT_OVERLAY_PATH)"
	@echo "  Overlay Dir OV:  $(INPUT_OVERLAY_DIR)"
	@echo "  U-Boot Dir OV:   $(INPUT_UBOOT_DIR)"
	@echo
	@echo "Output"
	@echo "  System Image:    $(OUTPUT_24_04_SYSTEM_IMAGE)"
	@echo "  Debug:           $(DEBUG)"
	@echo "  Input Env:       $(if $(strip $(INPUT_ENV)), $(INPUT_ENV), <none>)"
	@echo ""
	@echo	"**************************************************"
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
	@echo "Tachyon System Image Composer v$(VERSION)"
	@echo ""
	@echo "Available commands:"
	@echo "  build_24.04                 Build a Tachyon System Image for Ubuntu 24.04 base"
	@echo "  fetch_20_04                 Download Ubuntu 20.04 base zip to $(TMP_INPUT_DIR)"
	@echo "  fetch_uboot                 Download U-Boot zip to $(TMP_INPUT_DIR)"
	@echo "  fetch_24_04                 Download Ubuntu 24.04 .img.xz to $(TMP_INPUT_DIR)"
	@echo "  fetch_24_04_unxz            Decompress 24.04 .img.xz to .img using Docker"
	@echo "  doctor                      Minimal host prerequisites check (docker, git, QEMU)"
	@echo "  check_qemu                  Check if QEMU ARM64 emulation is configured"
	@echo "  setup_qemu                  Setup QEMU ARM64 emulation (x86_64 hosts only)"
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
	@echo "  VERSIONS_FILE               Path to a JSON file with source versions (overrides individual inputs)"
	@echo "  INPUT_UBOOT_DIR             Path to local U-Boot directory (skip downloading U-Boot if set)"
	@echo "  INPUT_OVERLAY_DIR           Path to local overlays directory (skip cloning tachyon-overlays if set)"
	@echo "  INPUT_OVERLAY_STACK         Overlay stack/branch name to use (e.g., ubuntu-headless-24.04)"
	@echo "  INPUT_ENV_VARS              Comma-separated package version env vars (e.g., PKG_name=ver,...)"
	@echo ""
	@echo "Examples:"
	@echo "  make build_24.04 COMMAND=build_24.04 INPUT_BASE_20_04_VERSION=1.0.167 INPUT_REGION=RoW INPUT_VARIANT=desktop INPUT_UBOOT_VERSION=1.0.3 INPUT_BASE_24_04_VERSION=14-276cd6b"
	@echo "  make fetch_20_04 INPUT_BASE_20_04_VERSION=1.0.167 INPUT_REGION=RoW INPUT_VARIANT=desktop"
	@echo "  make build_24.04 VERSIONS_FILE=./versions.json INPUT_REGION=RoW INPUT_VARIANT=headless"
	@echo "  make build_24.04 INPUT_BASE_20_04_VERSION=1.0.169 INPUT_REGION=RoW INPUT_VARIANT=desktop INPUT_BASE_24_04_VERSION=14-276cd6b INPUT_UBOOT_DIR=../my-uboot-build INPUT_OVERLAY_DIR=./my-overlays"
	@echo ""

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

fetch_uboot: docker/build
	@if [ -n "$(INPUT_UBOOT_DIR)" ]; then \
		echo "Using local U-Boot from $(INPUT_UBOOT_DIR)"; \
		rm -rf "$(TMP_INPUT_DIR)/u-boot"; \
		mkdir -p "$(TMP_INPUT_DIR)/u-boot"; \
		cp -r "$(INPUT_UBOOT_DIR)/." "$(TMP_INPUT_DIR)/u-boot/"; \
		echo "Copied local U-Boot files to $(TMP_INPUT_DIR)/u-boot"; \
	else \
		if [ -f "$(UBOOT_ZIP)" ]; then \
			echo "File $(UBOOT_ZIP) already exists, skipping download"; \
		else \
			$(DOCKER_RUN) bash -lc 'set -euo pipefail; \
				mkdir -p "$(TMP_INPUT_DIR)"; \
				echo "==> Downloading U-Boot: $(UBOOT_URL_PRIMARY) (fallback: encoded path)"; \
				{ curl -fL --retry 3 -o "$(UBOOT_ZIP)" "$(UBOOT_URL_PRIMARY)" || curl -fL --retry 3 -o "$(UBOOT_ZIP)" "$(UBOOT_URL_ENCODED)"; } \
				  || { echo "Error: failed to download U-Boot from both $(UBOOT_URL_PRIMARY) and $(UBOOT_URL_ENCODED)"; rm -f "$(UBOOT_ZIP)"; exit 1; }; \
				test -s "$(UBOOT_ZIP)" || { echo "Error: downloaded file is empty: $(UBOOT_ZIP)"; exit 1; }; \
				echo "Downloaded U-Boot: $(UBOOT_ZIP)"; \
				unzip -o "$(UBOOT_ZIP)" -d "$(TMP_INPUT_DIR)/u-boot" >/dev/null; \
				echo "Unzipped U-Boot to $(TMP_INPUT_DIR)/u-boot"'; \
		fi; \
	fi

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
		OUTPUT_VERSION="$(OUTPUT_VERSION)" \
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
# tachyon-overlay-tool tool fetch/setup inside Docker
# -------------------------------------------------------------------

# Directory INSIDE the container where tachyon-overlay-tool will be cloned
OVERLAY_TOOL_DIR      := /tmp/work/tools/tachyon-overlay-tool

# Clone URL for the overlay tool
OVERLAY_TOOL_CLONE_URL = https://github.com/particle-iot/tachyon-overlay-tool.git

# Pin to a branch/tag/commit if desired: OVERLAY_TOOL_REF=main (or a SHA)
OVERLAY_TOOL_REF      ?= main
OVERLAY_TOOL_STAMP    := $(OVERLAY_TOOL_DIR)/.installed

.PHONY: fetch_overlay_tool
fetch_overlay_tool: $(OVERLAY_TOOL_STAMP)

# Clone (or update) tachyon-overlay-tool inside the builder container
$(OVERLAY_TOOL_STAMP): docker/build
	@echo "==> Setting up tachyon-overlay-tool tool inside Docker"
	@mkdir -p "$(OVERLAY_TOOL_DIR)"
	@$(DOCKER_RUN) bash -lc 'set -euo pipefail; \
		if [ ! -d "$(OVERLAY_TOOL_DIR)/.git" ]; then \
			echo "Cloning $(OVERLAY_TOOL_CLONE_URL) -> $(OVERLAY_TOOL_DIR)"; \
			git clone --depth 1 "$(OVERLAY_TOOL_CLONE_URL)" "$(OVERLAY_TOOL_DIR)"; \
		else \
			echo "$(OVERLAY_TOOL_DIR) already present"; \
		fi; \
		echo "Checking out $(OVERLAY_TOOL_REF)"; \
		git -C "$(OVERLAY_TOOL_DIR)" fetch --depth 1 origin "$(OVERLAY_TOOL_REF)"; \
		git -C "$(OVERLAY_TOOL_DIR)" checkout -q FETCH_HEAD; \
		# Optional: install Python deps if the project defines them \
		if [ -f "$(OVERLAY_TOOL_DIR)/requirements.txt" ]; then \
			pip3 install --user --no-cache-dir -r "$(OVERLAY_TOOL_DIR)/requirements.txt" || \
			  sudo pip3 install --break-system-packages --no-cache-dir -r "$(OVERLAY_TOOL_DIR)/requirements.txt"; \
		fi; \
		# Sanity check expected entrypoints exist \
		{ test -f "$(OVERLAY_TOOL_DIR)/overlay.py" && test -f "$(OVERLAY_TOOL_DIR)/run-overlay.sh"; } || { \
			echo "Error: expected overlay.py and run-overlay.sh not found in $(OVERLAY_TOOL_DIR)"; exit 1; }; \
		touch "$(OVERLAY_TOOL_DIR)/.installed"'
	@echo "Installed tachyon-overlay-tool to $(OVERLAY_TOOL_DIR)"

# -------------------------------------------------------------------
# tachyon-overlays fetch/setup inside Docker
# -------------------------------------------------------------------

# Directory INSIDE the container where the repo will be cloned
OVERLAYS_REPO_DIR      := $(INPUT_OVERLAY_DOCKER_PATH)

.PHONY: fetch_tachyon_overlays
fetch_tachyon_overlays: docker/build
	@if [ -n "$(INPUT_OVERLAY_DIR)" ]; then \
		echo "Using local overlays from $(INPUT_OVERLAY_DIR)"; \
		rm -rf $(TMP_ROOT_DIR)/input/tachyon-overlays; \
		mkdir -p $(TMP_ROOT_DIR)/input/tachyon-overlays; \
		cp -r "$(INPUT_OVERLAY_DIR)/." $(TMP_ROOT_DIR)/input/tachyon-overlays/; \
		echo "Copied local overlays to $(TMP_ROOT_DIR)/input/tachyon-overlays"; \
		touch $(TMP_ROOT_DIR)/input/tachyon-overlays/.installed; \
	else \
		echo "==> Fetching tachyon-overlays into $(INPUT_OVERLAY_DOCKER_PATH) inside Docker"; \
		$(DOCKER_RUN) bash -lc 'set -euo pipefail; \
			DEST="$(INPUT_OVERLAY_DOCKER_PATH)"; \
			echo "Using overlay destination: $$DEST"; \
			mkdir -p "$(dir $(OVERLAYS_REPO_DIR))" "$$DEST"; \
			if [ ! -d "$(OVERLAYS_REPO_DIR)/.git" ]; then \
				echo "Cloning https://github.com/particle-iot/tachyon-overlays.git -> $(OVERLAYS_REPO_DIR)"; \
				git clone --depth 1 https://github.com/particle-iot/tachyon-overlays.git "$(OVERLAYS_REPO_DIR)"; \
			else \
				echo "$(OVERLAYS_REPO_DIR) already present"; \
			fi; \
			echo "Checking out $(OVERLAYS_REF)"; \
			if [ "$(OVERLAYS_REF)" = "HEAD" ]; then \
				echo "Using latest HEAD of default branch"; \
			else \
				git -C "$(OVERLAYS_REPO_DIR)" fetch --depth 1 origin "$(OVERLAYS_REF)"; \
				git -C "$(OVERLAYS_REPO_DIR)" checkout -q FETCH_HEAD; \
			fi; \
			touch "$$DEST/.installed"'; \
		echo "Installed tachyon-overlays into $(INPUT_OVERLAY_DOCKER_PATH)"; \
	fi

# -------------------------------------------------------------------
# Main build command for Ubuntu 24.04
# -------------------------------------------------------------------
# Helper basenames for use inside the container
BASE24_IMG_BASENAME := $(notdir $(BASE24_IMG))

.PHONY: build_24.04
build_24.04: version print-config check_qemu fetch_tachyon_overlays fetch_overlay_tool fetch_qtools fetch_20_04 fetch_uboot fetch_24_04_unxz prepare_base_24_04 docker/build 
	@echo "Building Tachyon System Image for Ubuntu 24.04..."
	@echo ""
	$(call check_required_param,INPUT_BASE_20_04_VERSION)
	$(call check_required_param,INPUT_REGION)
	$(call check_required_param,INPUT_VARIANT)
	$(call check_required_param,INPUT_BASE_24_04_VERSION)
	$(call validate_region)
	$(call validate_variant)
	$(call validate_semver,INPUT_BASE_20_04_VERSION)
	@if [ -z "$(INPUT_UBOOT_VERSION)" ] && [ -z "$(INPUT_UBOOT_DIR)" ]; then \
		echo "Error: INPUT_UBOOT_VERSION or INPUT_UBOOT_DIR is required"; \
		exit 1; \
	fi
	$(eval GENERATED_DISTRO_ENV := PKG_DISTRO_VERSION=$(OUTPUT_VERSION)$(comma)PKG_DISTRO_STACK=$(if $(INPUT_OVERLAY_STACK),$(INPUT_OVERLAY_STACK),ubuntu-$(INPUT_VARIANT)-24.04)$(comma)PKG_DISTRO_VARIANT=$(INPUT_VARIANT)$(comma)PKG_DISTRO_REGION=$(INPUT_REGION)$(comma)PKG_DISTRO_BOARD=formfactor_dvt$(comma)PKG_DISTRO_DISTRIBUTION=ubuntu$(comma)PKG_DISTRO_DISTRIBUTION_VERSION=24.04)
	$(eval GENERATED_SRC_ENV := PKG_SRC_TACHYON_COMPOSER=$(VERSION)$(comma)PKG_SRC_UBUNTU_20_04=$(INPUT_BASE_20_04_VERSION)$(comma)PKG_SRC_UBUNTU_24_04=$(INPUT_BASE_24_04_VERSION)$(comma)PKG_SRC_U_BOOT=$(INPUT_UBOOT_VERSION)$(comma)PKG_SRC_OVERLAYS=$(OVERLAYS_REF))
	$(eval GENERATED_ENV := $(GENERATED_DISTRO_ENV)$(comma)$(GENERATED_SRC_ENV))
	$(eval COMBINED_ENV := $(if $(strip $(INPUT_ENV)),$(INPUT_ENV)$(comma),)$(GENERATED_ENV))
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
	@echo "  Debug:              $(DEBUG)"
	@echo "  Input Env:          $(if $(INPUT_ENV),$(INPUT_ENV),<none>)"
	@echo "  Generated Env:      $(GENERATED_ENV)"
	@echo "  Input Overlay Path: $(INPUT_OVERLAY_PATH)"
	@echo ""
	@mkdir -p $(TMP_INPUT_DIR)
	@mkdir -p $(TMP_OUTPUT_DIR)
	@echo "Step 1: Base assets available in $(TMP_INPUT_DIR)"
	@echo "  - 20.04: $(notdir $(BASE20_ZIP)) in $(TMP_INPUT_DIR)/sys-img-20.04"
	@echo "  - U-Boot: $(notdir $(UBOOT_ZIP)) in $(TMP_INPUT_DIR)/u-boot"
	@echo "  - 24.04 img: $(notdir $(BASE24_IMG)) in $(TMP_INPUT_DIR)/sys-img-24.04"
	@echo ""
	@$(DOCKER_RUN) bash ./compose_24_04.sh "$(UBOOT_DIR)" "$(BASE24_IMG_BASENAME)" "$(BASE24_SYSTEM_IMAGE_DIR)" "$(OUTPUT_24_04_SYSTEM_IMAGE)" "$(DEBUG)" "$(INPUT_OVERLAY_DOCKER_PATH)" "$(COMBINED_ENV)" "$(INPUT_KERNEL_VERSION)"
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
# In CI (env CI=true), drop -it to avoid "the input device is not a TTY"
DOCKER_TTY := $(if $(CI),, -it)

DOCKER_RUN := docker run --rm $(DOCKER_TTY) --privileged \
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
	@$(MAKE) check_qemu

.PHONY: check_qemu
check_qemu:
	@HOST_ARCH=$$(uname -m); \
	HOST_OS=$$(uname -s); \
	if [ "$$HOST_ARCH" = "x86_64" ] || [ "$$HOST_ARCH" = "amd64" ]; then \
		if [ "$$HOST_OS" = "Linux" ]; then \
			if [ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then \
				echo "==> Setting up QEMU ARM64 emulation for x86_64 Linux host"; \
				echo "Running: docker run --rm --privileged multiarch/qemu-user-static --reset -p yes"; \
				docker run --rm --privileged multiarch/qemu-user-static --reset -p yes; \
				if [ -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then \
					echo "QEMU ARM64 emulation configured successfully"; \
				else \
					echo "ERROR: Failed to configure QEMU emulation"; \
					echo "Please manually install qemu-user-static:"; \
					echo "  sudo apt-get install -y qemu-user-static binfmt-support"; \
					exit 1; \
				fi; \
			fi; \
		fi; \
	fi

.PHONY: setup_qemu
setup_qemu:
	@echo "==> Setting up QEMU user-mode emulation"
	@HOST_ARCH=$$(uname -m); \
	if [ "$$HOST_ARCH" = "x86_64" ] || [ "$$HOST_ARCH" = "amd64" ]; then \
		echo "Registering QEMU binfmt_misc handlers..."; \
		docker run --rm --privileged multiarch/qemu-user-static --reset -p yes; \
		echo "QEMU setup complete"; \
	else \
		echo "Not needed on $$HOST_ARCH architecture"; \
	fi

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