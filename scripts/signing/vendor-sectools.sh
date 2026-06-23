#!/usr/bin/env bash
# vendor-sectools.sh — refresh the committed sectoolsv2 signer used by sign.sh.
#
# The composer signs (re-signs) the QCM6490 boot blobs with Qualcomm's compiled sectoolsv2.
# We commit just two files so signing works in CI without a BP-repo checkout:
#   sectools/ext/Linux_aarch64/sectools   the aarch64 sectools binary (runs in the arm64 builder)
#   sectools/kodiak_security_profile.xml  the QCM6490 (KODIAK) security profile
#
# This script copies those two from a local checkout of the BP firmware repo (or a URL) so a
# maintainer can update them when the BP toolchain bumps. It is a DEV/maintenance step — the build
# itself uses the committed files and never reaches into the BP repo.
#
# Usage:
#   vendor-sectools.sh --from-bp /path/to/tachyon-quectel-bp-fw
#   vendor-sectools.sh --binary-url <url> --profile-url <url>
#   vendor-sectools.sh            # defaults to ../tachyon-quectel-bp-fw relative to repo root
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${SCRIPT_DIR}/sectools"
# path within the BP repo to the QCM6490 sectoolsv2
SRC_REL="QCM6490.LE.1.0/common/sectoolsv2"

BP_DIR="" BIN_URL="" PROFILE_URL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-bp) BP_DIR="${2:?}"; shift 2 ;;
    --binary-url) BIN_URL="${2:?}"; shift 2 ;;
    --profile-url) PROFILE_URL="${2:?}"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "[ERROR] unknown arg: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "${DEST}/ext/Linux_aarch64"

if [[ -n "${BIN_URL}" ]]; then
  echo "[INFO] fetching sectools binary from ${BIN_URL}"
  curl -fsSL -o "${DEST}/ext/Linux_aarch64/sectools" "${BIN_URL}"
  chmod +x "${DEST}/ext/Linux_aarch64/sectools"
  [[ -n "${PROFILE_URL}" ]] && { echo "[INFO] fetching profile from ${PROFILE_URL}"; curl -fsSL -o "${DEST}/kodiak_security_profile.xml" "${PROFILE_URL}"; }
else
  [[ -n "${BP_DIR}" ]] || BP_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)/tachyon-quectel-bp-fw"
  SRC="${BP_DIR}/${SRC_REL}"
  echo "[INFO] vendoring sectoolsv2 (aarch64) + kodiak profile from ${SRC}"
  [[ -f "${SRC}/ext/Linux_aarch64/sectools" ]] \
    || { echo "[ERROR] not found: ${SRC}/ext/Linux_aarch64/sectools" >&2; exit 1; }
  cp "${SRC}/ext/Linux_aarch64/sectools" "${DEST}/ext/Linux_aarch64/sectools"
  chmod +x "${DEST}/ext/Linux_aarch64/sectools"
  cp "${SRC}/kodiak_security_profile.xml" "${DEST}/kodiak_security_profile.xml"
fi

[[ -x "${DEST}/ext/Linux_aarch64/sectools" && -f "${DEST}/kodiak_security_profile.xml" ]] \
  || { echo "[ERROR] vendoring incomplete" >&2; exit 1; }
echo "[OK] sectools vendored:"
echo "     binary : ${DEST}/ext/Linux_aarch64/sectools"
echo "     profile: ${DEST}/kodiak_security_profile.xml"
