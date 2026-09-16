# QLI userspace and its independent 1.4+ release stream.
QLI_VERSIONS_FILE ?= $(VERSIONS_FILE)
QLI_OUTPUT_VERSION ?= $(shell python3 scripts/qli/release-version.py prerelease)
QLI_BUILDER_IMAGE ?= tachyon-system-image-builder:qli-2.0-3
QLI_BASE_BUILDER_IMAGE ?= tachyon-system-image-builder:qli-base-1.4

.PHONY: fetch_qli fetch_qli_recovery build_qli test_qli docker/qli
fetch_qli:
	python3 scripts/qli/assets.py "$(QLI_VERSIONS_FILE)" .tmp/qli/input

fetch_qli_recovery:
	python3 scripts/qli/fetch-recovery.py "$(QLI_VERSIONS_FILE)" "$(INPUT_REGION)" .tmp/qli/recovery

docker/qli: check_qemu
	docker build --platform linux/arm64 --build-arg UID=1001 --build-arg GID=1001 -t "$(QLI_BASE_BUILDER_IMAGE)" .
	docker build --platform linux/arm64 -f scripts/qli/Dockerfile --build-arg "BUILDER_IMAGE=$(QLI_BASE_BUILDER_IMAGE)" -t "$(QLI_BUILDER_IMAGE)" scripts/qli

.PHONY: check_qli_packages fetch_qli_overlays
check_qli_packages:
	python3 scripts/qli/rpm_repository.py "$(QLI_VERSIONS_FILE)"

fetch_qli_overlays:
	python3 scripts/qli/checkout.py "$(QLI_VERSIONS_FILE)" overlays .tmp/qli/overlays
	python3 scripts/qli/checkout.py "$(QLI_VERSIONS_FILE)" overlay_tool .tmp/qli/overlay-tool

build_qli: check_qli_packages docker/qli check_qemu fetch_qli fetch_qli_overlays
	@test "$(INPUT_REGION)" = NA -o "$(INPUT_REGION)" = RoW || { echo 'INPUT_REGION must be NA or RoW'; exit 1; }
	@mkdir -p .tmp/qli/output
	docker run --rm --privileged --user root \
		-v "$(CURDIR):/project:ro" -v "$(CURDIR)/.tmp/qli:/work" \
		-w /project "$(QLI_BUILDER_IMAGE)" bash compose_qli.sh \
		"$(QLI_VERSIONS_FILE)" "$(INPUT_REGION)" "$(QLI_OUTPUT_VERSION)"

test_qli:
	python3 -m unittest discover -s scripts/qli -p 'test_*.py' -v
	@for script in compose_qli.sh scripts/qli/*.sh; do bash -n "$$script" || exit; done
	@for script in scripts/qli/initramfs-* scripts/qli/tachyon-adb; do sh -n "$$script" || exit; done
