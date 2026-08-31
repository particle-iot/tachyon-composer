#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Tachyon uses UFS 2.2 chip.
# (tachyon-eugene: xml/provision vendored under ./config/, self-contained)
PROVISION_XML="${SCRIPT_DIR}/config/provision_ufs22.xml"
PARTITION_EXT_XML="${SCRIPT_DIR}/config/partition_ext.xml"

usage() {
  cat <<'EOF'
Usage:
  make_factory_img.sh \
    --bootbinaries /path/to/QCM6490_bootbinaries.zip \
    --<partition_name> /path/to/partition.img \
    [--<partition_name> /path/to/partition.img ...] \
    --output /path/to/out
EOF
}

require_file() {
  local path="$1"
  if [[ ! -f "${path}" ]]; then
    echo "[ERROR] Missing file: ${path}" >&2
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

BOOTBINARIES_ZIP=""
OUTPUT_DIR="$(pwd)/output"
declare -a PARTITION_LABELS=()
declare -a PARTITION_FILES=()

update_partition_filename() {
  local xml_path="$1"
  local label="$2"
  local filename="$3"

  if ! python3 - "${xml_path}" "${label}" "${filename}" <<'PY'
import re
import sys

xml_path, label, filename = sys.argv[1:]
pattern = re.compile(r'(<partition\b[^>]*\blabel="%s"[^>]*\bfilename=")[^"]*(")' % re.escape(label))

with open(xml_path, 'r', encoding='utf-8') as f:
    content = f.read()

updated, count = pattern.subn(lambda m: f"{m.group(1)}{filename}{m.group(2)}", content)
if count == 0:
    sys.exit(1)

with open(xml_path, 'w', encoding='utf-8') as f:
    f.write(updated)
PY
  then
    echo "[ERROR] Unknown partition label: ${label}" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bootbinaries)
      BOOTBINARIES_ZIP="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --*)
      if [[ $# -lt 2 ]]; then
        echo "[ERROR] Missing value for argument: $1" >&2
        usage >&2
        exit 1
      fi
      PARTITION_LABELS+=("${1#--}")
      PARTITION_FILES+=("${2:-}")
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

if [[ -z "${BOOTBINARIES_ZIP}" ]]; then
  usage >&2
  exit 1
fi

require_cmd unzip
require_cmd python3
require_file "${BOOTBINARIES_ZIP}"
require_file "${SCRIPT_DIR}/ptool.py"
require_file "${PARTITION_EXT_XML}"
require_file "${PROVISION_XML}"
require_file "${SCRIPT_DIR}/cdt.bin"

for partition_file in "${PARTITION_FILES[@]}"; do
  require_file "${partition_file}"
done

mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"
# Guard: --output is user-supplied and we wipe it below. Refuse paths that would clear the
# filesystem root (or a top-level dir), since `rm -rf <dir>/*` on those is catastrophic.
if [[ "${OUTPUT_DIR}" == "/" || "${OUTPUT_DIR}" != /*/* ]]; then
  echo "ERROR: refusing to wipe unsafe --output path '${OUTPUT_DIR}' (must be at least two levels deep)" >&2
  exit 1
fi
rm -rf "${OUTPUT_DIR:?}/"*

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

unzip -q "${BOOTBINARIES_ZIP}" -d "${work_dir}/unzipped"

if [[ -d "${work_dir}/unzipped/QCM6490_bootbinaries" ]]; then
  cp -r "${work_dir}/unzipped/QCM6490_bootbinaries/." "${OUTPUT_DIR}/"
else
  cp -r "${work_dir}/unzipped/." "${OUTPUT_DIR}/"
fi

cp "${SCRIPT_DIR}/cdt.bin" "${OUTPUT_DIR}/cdt.bin"
cp "${PARTITION_EXT_XML}" "${OUTPUT_DIR}/partition_ext.xml"
cp "${PROVISION_XML}" "${OUTPUT_DIR}/provision_ufs22.xml"

for i in "${!PARTITION_LABELS[@]}"; do
  partition_label="${PARTITION_LABELS[$i]}"
  partition_file="${PARTITION_FILES[$i]}"
  partition_basename="$(basename "${partition_file}")"

  update_partition_filename "${OUTPUT_DIR}/partition_ext.xml" "${partition_label}" "${partition_basename}"
  cp "${partition_file}" "${OUTPUT_DIR}/${partition_basename}"
done

(
  cd "${OUTPUT_DIR}"
  if ! python3 "${SCRIPT_DIR}/ptool.py" -x "${OUTPUT_DIR}/partition_ext.xml" > "${OUTPUT_DIR}/ptool.log" 2>&1; then
    echo "[ERROR] ptool failed, see ${OUTPUT_DIR}/ptool.log" >&2
    exit 1
  fi
)

# The provisioning descriptor and the partition layout are two files that have to agree and
# had nothing checking that they did. They have disagreed twice, and both times shipped: the
# LUN 4 overrun that made every flash onto a 20.04-geometry board time out, and LUN 6 being
# left disabled after #68 moved the whole firmware set onto it. Validate the descriptor
# against the rawprograms ptool just generated, so a disagreement fails here rather than on
# somebody's board.
if ! python3 "${SCRIPT_DIR}/validate_provisioning.py" \
      --provision "${OUTPUT_DIR}/provision_ufs22.xml" \
      --dir "${OUTPUT_DIR}"; then
  echo "[ERROR] provisioning descriptor does not match the generated partition layout" >&2
  exit 1
fi

echo "[OK] Output prepared at ${OUTPUT_DIR}"
