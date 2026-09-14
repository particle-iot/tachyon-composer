# Standalone experimental userspace; no Ubuntu overlay or release publication.
QLI_VERSIONS_FILE ?= versions-qli-2.0.json
QLI_OUTPUT_VERSION ?= 0.1.0-qli.2.0.g$(shell git rev-parse --short HEAD)
QLI_BUILDER_IMAGE ?= tachyon-system-image-builder:qli-2.0-2

.PHONY: fetch_qli fetch_qli_recovery build_qli test_qli docker/qli
fetch_qli:
	python3 scripts/qli/assets.py "$(QLI_VERSIONS_FILE)" .tmp/qli/input

fetch_qli_recovery:
	python3 scripts/qli/fetch-recovery.py "$(QLI_VERSIONS_FILE)" "$(INPUT_REGION)" .tmp/qli/recovery

docker/qli: docker/build
	@test "$$(docker image inspect --format '{{.Architecture}}' "$(IMAGE_TAG)")" = arm64 || { echo 'QLI needs an ARM64 builder image (build Dockerfile with --platform linux/arm64)'; exit 1; }
	docker build -f scripts/qli/Dockerfile --build-arg "BUILDER_IMAGE=$(IMAGE_TAG)" -t "$(QLI_BUILDER_IMAGE)" scripts/qli

build_qli: docker/qli check_qemu fetch_qli
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
