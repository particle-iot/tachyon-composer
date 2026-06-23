#!/usr/bin/env bash
# sign.sh — (re)sign the Tachyon boot/firmware blobs with a selectable key.
#
# The single signing entry point the composer calls. Self-contained so the whole scripts/signing/
# folder can be lifted into its own repo unchanged. It signs each blob listed in image-map.tsv
# with Qualcomm's sectoolsv2 and passes everything else through.
#
# The BP artifact ships the boot blobs already TEST-signed (signed inside the Qualcomm sub-builds).
# This tool RE-SIGNS them with the selected key: the same stock TEST key for now (proving the
# selectable-key path), a real OEM/prod key later. Re-signing a signed image is supported by
# sectoolsv2 (it regenerates the hash table + cert chain).
#
# Usage:
#   sign.sh --in <dir> --out <dir> [--profile test|prod|none] [--key <name>]
#           [--keys-dir <dir>] [--fw-dir <QCM6490_fw>] [--map <image-map.tsv>]
#           [--sectools <dir>] [--profile-xml <xml>]
#
# --fw-dir is the extracted QCM6490_fw tree; multi_image.mbn vouches for ADSP/CDSP/WPSS which
# live there (not in the bootbinaries). Without it, multi_image is carried over and flagged.
#
# profile=test -> sectoolsv2 --signing-mode TEST (built-in Qualcomm test keys; no key material).
# profile=prod -> sectoolsv2 --signing-mode LOCAL with OEM keys from $SIGNING_KEY_PATH (a mounted
#                 dir, NEVER committed). Wired but not populated until a prod key exists.
# profile=none -> passthrough: copy every input unchanged, sign nothing (use the BP test-signing).
#
# NOTE: --key / --keys-dir (and versions.json signing.key) are RESERVED for prod (LOCAL) signing
# and are NOT consumed today: TEST mode uses sectoolsv2's built-in keys. They are accepted now so
# the Makefile/versions.json wiring is stable; they get wired into the LOCAL key args at prod
# enablement. Passing them with profile=test/none has no effect.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# scripts/signing/ -> repo root is two levels up
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

IN_DIR="" OUT_DIR="" PROFILE="" KEY="" FW_DIR=""
KEYS_DIR="${REPO_DIR}/keys"
MAP="${SCRIPT_DIR}/image-map.tsv"
SECTOOLS_DIR="${SCRIPT_DIR}/sectools"
PROFILE_XML=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --in) IN_DIR="${2:?}"; shift 2 ;;
    --out) OUT_DIR="${2:?}"; shift 2 ;;
    --profile) PROFILE="${2:?}"; shift 2 ;;
    --key) KEY="${2:?}"; shift 2 ;;
    --keys-dir) KEYS_DIR="${2:?}"; shift 2 ;;
    --fw-dir) FW_DIR="${2:?}"; shift 2 ;;
    --map) MAP="${2:?}"; shift 2 ;;
    --sectools) SECTOOLS_DIR="${2:?}"; shift 2 ;;
    --profile-xml) PROFILE_XML="${2:?}"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "[ERROR] unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -n "${IN_DIR}" && -n "${OUT_DIR}" ]] || { echo "[ERROR] --in and --out are required" >&2; exit 1; }
[[ -d "${IN_DIR}" ]] || { echo "[ERROR] input dir not found: ${IN_DIR}" >&2; exit 1; }
[[ -f "${MAP}" ]] || { echo "[ERROR] image map not found: ${MAP}" >&2; exit 1; }

# --- resolve profile/key from versions.json if not given on CLI ---------------
read_versions_signing() {
  local f="${REPO_DIR}/versions.json" field="$1"
  [[ -f "${f}" ]] || return 0
  python3 - "${f}" "${field}" <<'PY' 2>/dev/null || true
import json,re,sys
raw=open(sys.argv[1]).read()
raw="\n".join(l for l in raw.splitlines() if not l.strip().startswith("//"))
try: d=json.loads(raw)
except Exception: sys.exit(0)
print((d.get("signing") or {}).get(sys.argv[2],""))
PY
}
[[ -z "${PROFILE}" ]] && PROFILE="$(read_versions_signing profile)"; PROFILE="${PROFILE:-test}"
[[ -z "${KEY}" ]] && KEY="$(read_versions_signing key)"

mkdir -p "${OUT_DIR}"

# --- passthrough (sign nothing) -----------------------------------------------
if [[ "${PROFILE}" == "none" ]]; then
  echo "[INFO] profile=none — passthrough, signing nothing (using the bp-fw test signing)"
  cp -a "${IN_DIR}/." "${OUT_DIR}/"
  echo "[OK] passthrough -> ${OUT_DIR}"
  exit 0
fi

# --- resolve signing mode -----------------------------------------------------
case "${PROFILE}" in
  test)
    SIGNING_MODE="TEST"
    echo "[INFO] profile=test — sectoolsv2 --signing-mode TEST (stock Qualcomm test keys)"
    echo "[WARN] TEST signing — NOT production-secure."
    ;;
  prod)
    SIGNING_MODE="LOCAL"
    [[ -n "${SIGNING_KEY_PATH:-}" && -d "${SIGNING_KEY_PATH}" ]] \
      || { echo "[ERROR] profile=prod requires SIGNING_KEY_PATH to a mounted OEM key dir (never committed)" >&2; exit 1; }
    echo "[INFO] profile=prod — sectoolsv2 --signing-mode LOCAL, keys from ${SIGNING_KEY_PATH}"
    # NOTE: prod key flags (--root-key/--ca-key/...) are wired during prod enablement.
    ;;
  *) echo "[ERROR] unknown profile: ${PROFILE} (expected test|prod|none)" >&2; exit 1 ;;
esac

# --- locate sectoolsv2 + the kodiak security profile --------------------------
SECTOOLS="${SECTOOLS_DIR}/ext/Linux_aarch64/sectools"
[[ -x "${SECTOOLS}" ]] || { echo "[ERROR] sectoolsv2 not found/executable: ${SECTOOLS} (run vendor-sectools.sh)" >&2; exit 1; }
[[ -n "${PROFILE_XML}" ]] || PROFILE_XML="${SECTOOLS_DIR}/kodiak_security_profile.xml"
[[ -f "${PROFILE_XML}" ]] || { echo "[ERROR] security profile not found: ${PROFILE_XML}" >&2; exit 1; }

# sectoolsv2 is a PyInstaller bundle that dlopen()s libcrypt.so.2; Ubuntu 24.04 ships only
# libcrypt.so.1. Provide a libcrypt.so.2 via an LD_LIBRARY_PATH shim — no root needed, so this
# works whether or not the Dockerfile baked the symlink.
if ! ldconfig -p 2>/dev/null | grep -q "libcrypt.so.2"; then
  L="$(find /usr/lib /lib -name 'libcrypt.so.1' 2>/dev/null | head -1 || true)"
  if [[ -n "${L}" ]]; then
    LIBSHIM="$(mktemp -d)"; ln -s "${L}" "${LIBSHIM}/libcrypt.so.2"
    export LD_LIBRARY_PATH="${LIBSHIM}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
  fi
fi

prod_key_args=()
[[ "${SIGNING_MODE}" == "LOCAL" ]] && prod_key_args=( )  # placeholder: populate from SIGNING_KEY_PATH at prod enablement

# Carry over EVERY input first (the set contains files not in the map — keep them), then overwrite
# the sign=yes blobs with re-signed versions.
cp -a "${IN_DIR}/." "${OUT_DIR}/"

# multi_image.mbn vouches for the hashes of this fixed, ordered image set (matches the BP build's
# metabuild-secure-image --vouch-for --image-id ...). 10 come from the re-signed bootbinaries, the
# last 3 (ADSP/CDSP/WPSS) live in QCM6490_fw (--fw-dir). Re-signing the boot blobs changes their
# hashes, so multi_image must be regenerated to vouch for the re-signed versions.
MULTI_IMAGE_FILE="multi_image.mbn"
VOUCH_IDS=(QUPV3 AOP SHRM XBL-CONFIG UEFI XBL-RAM-DUMP CPUCP TZ QHEE TZ-DEVCFG ADSP CDSP WPSS)
# image-id : filename : source (boot=OUT_DIR re-signed | fw=FW_DIR)
VOUCH_MAP=(
  "QUPV3:qupv3fw.elf:boot" "AOP:aop.mbn:boot" "SHRM:shrm.elf:boot" "XBL-CONFIG:xbl_config.elf:boot"
  "UEFI:uefi.elf:boot" "XBL-RAM-DUMP:XblRamdump.elf:boot" "CPUCP:cpucp.elf:boot" "TZ:tz.mbn:boot"
  "QHEE:hypvm.mbn:boot" "TZ-DEVCFG:devcfg.mbn:boot"
  "ADSP:adsp.mbn:fw" "CDSP:cdsp.mbn:fw" "WPSS:wpss.mbn:fw"
)

# --- iterate the map: per-blob re-sign ----------------------------------------
signed=0 missing=0
while IFS=$'\t' read -r filename image_id sign note; do
  [[ -z "${filename}" || "${filename}" == \#* ]] && continue
  case "${sign}" in
    yes)
      src="${IN_DIR}/${filename}"; dst="${OUT_DIR}/${filename}"
      if [[ ! -f "${src}" ]]; then
        echo "[WARN] expected blob missing in input: ${filename}"; missing=$((missing+1)); continue
      fi
      echo "[SIGN] ${filename}  (image-id=${image_id}, mode=${SIGNING_MODE})"
      "${SECTOOLS}" secure-image "${src}" \
        --image-id "${image_id}" \
        --security-profile "${PROFILE_XML}" \
        --outfile "${dst}" \
        --sign --signing-mode "${SIGNING_MODE}" "${prod_key_args[@]}" >/dev/null
      signed=$((signed+1))
      ;;
    *) : ;;  # metabuild handled below; sign=no -> already carried over
  esac
done < "${MAP}"

# --- regenerate multi_image.mbn over the re-signed set ------------------------
fw_qcm="${FW_DIR%/}/lib/firmware/qcom/qcm6490"
resolve_vouch() { local file="$1" srcsel="$2"; [[ "${srcsel}" == fw ]] && echo "${fw_qcm}/${file}" || echo "${OUT_DIR}/${file}"; }
meta=0
if [[ -f "${IN_DIR}/${MULTI_IMAGE_FILE}" ]]; then
  vouch_files=() ok=1
  # --fw-dir is mandatory for regeneration: without it, fw paths would resolve to the absolute
  # host/container path /lib/firmware/qcom/qcm6490 and could silently vouch for the WRONG blobs.
  if [[ -z "${FW_DIR}" ]]; then
    echo "[WARN] multi_image: --fw-dir not given; cannot resolve ADSP/CDSP/WPSS — refusing to regenerate."
    ok=0
  fi
  for entry in "${VOUCH_MAP[@]}"; do
    [[ "${ok}" -eq 1 ]] || break
    IFS=: read -r _id fname srcsel <<<"${entry}"
    p="$(resolve_vouch "${fname}" "${srcsel}")"
    [[ -f "${p}" ]] || { echo "[WARN] multi_image vouch input missing: ${p}"; ok=0; }
    vouch_files+=("${p}")
  done
  if [[ "${ok}" -eq 1 ]]; then
    echo "[META] regenerating ${MULTI_IMAGE_FILE} (vouch-for ${#vouch_files[@]} images, mode=${SIGNING_MODE})"
    "${SECTOOLS}" secure-image \
      --vouch-for "${vouch_files[@]}" \
      --image-id "${VOUCH_IDS[@]}" \
      --security-profile "${PROFILE_XML}" \
      --outfile "${OUT_DIR}/${MULTI_IMAGE_FILE}" \
      --sign --signing-mode "${SIGNING_MODE}" "${prod_key_args[@]}" >/dev/null
    meta=1
  else
    echo "[WARN] ${MULTI_IMAGE_FILE}: vouch inputs incomplete (need --fw-dir for ADSP/CDSP/WPSS) — carried over."
    echo "       The carried multi_image is stale vs the re-signed blobs; fix before hardware/prod."
  fi
fi

echo "[OK] re-signed=${signed} multi_image_regenerated=${meta} missing=${missing} -> ${OUT_DIR}"
[[ "${missing}" -eq 0 ]] || { echo "[ERROR] ${missing} blob(s) marked sign=yes were missing from input" >&2; exit 1; }
