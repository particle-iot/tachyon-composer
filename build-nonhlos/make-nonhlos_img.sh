#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_SIZE_KIB=174080
IMAGE_SIZE_MIB=$((IMAGE_SIZE_KIB / 1024))

usage() {
  cat <<'EOF'
Usage:
  make-nonhlos_img.sh \
    --variant em|na \
    --output /path/to/nonhlos.img
EOF
}

require_dir() {
  local path="$1"
  if [[ ! -d "${path}" ]]; then
    echo "[ERROR] Missing directory: ${path}" >&2
    exit 1
  fi
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "[ERROR] Missing command: ${cmd}" >&2
    exit 1
  fi
}

VARIANT=""
OUTPUT_IMG="$(pwd)/nonhlos.img"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant)
      VARIANT="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_IMG="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${VARIANT}" ]]; then
  usage >&2
  exit 1
fi

if [[ "${VARIANT}" != "em" && "${VARIANT}" != "na" ]]; then
  echo "[ERROR] --variant must be 'em' or 'na'" >&2
  exit 1
fi

VARIANT_DIR="${SCRIPT_DIR}/${VARIANT}"

require_cmd mkfs.vfat
require_cmd mmd
require_cmd mcopy
require_dir "${VARIANT_DIR}/btfw"
require_dir "${VARIANT_DIR}/modem"
require_dir "${VARIANT_DIR}/wlan"

mkdir -p "$(dirname "${OUTPUT_IMG}")"
OUTPUT_IMG="$(cd "$(dirname "${OUTPUT_IMG}")" && pwd)/$(basename "${OUTPUT_IMG}")"
rm -f "${OUTPUT_IMG}"

dd if=/dev/zero of="${OUTPUT_IMG}" bs=1M count="${IMAGE_SIZE_MIB}" status=none
# FAT16 (not FAT32): at 170MiB with 4K logical sectors there are ~43520 clusters,
# which is below FAT32's 65525-cluster minimum (mkfs warns and the volume is then
# unreadable -> mcopy fails with "Cannot initialize '::'"). ~43520 falls inside the
# FAT16 range [4085, 65525), so FAT16+4K yields a valid, writable, vfat-mountable FS.
mkfs.vfat -F 16 -S 4096 "${OUTPUT_IMG}" >/dev/null

# Copy btfw/, modem/, wlan/ from variant directory
for dir in btfw modem wlan; do
  mmd -i "${OUTPUT_IMG}" "::/${dir}"
  mcopy -i "${OUTPUT_IMG}" -s "${VARIANT_DIR}/${dir}/"* "::/${dir}"
done

# Sanity: the variant firmware must actually be present (guard against the silent
# mtools failure mode where mcopy prints an error but still exits 0).
for dir in btfw modem wlan; do
  mdir -i "${OUTPUT_IMG}" "::/${dir}" >/dev/null \
    || { echo "[ERROR] ${dir}/ not present in ${OUTPUT_IMG}" >&2; exit 1; }
done

echo "[OK] Output prepared at ${OUTPUT_IMG}"
