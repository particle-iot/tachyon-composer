#!/usr/bin/env bash
# test_update_metadata.sh
# Usage:
#   ./test_update_metadata.sh \
#     --version 1.2.3 \
#     --na-zip ./tachyon-ubuntu-24.04-NA-desktop-1.2.3.zip \
#     --row-zip ./tachyon-ubuntu-24.04-RoW-desktop-1.2.3.zip \
#     --in releases.json \
#     --out releases.updated.json \
#     [--base-url https://linux-dist.particle.io/releases]

set -euo pipefail

VERSION=""
NA_ZIP=""
ROW_ZIP=""
IN_JSON=""
OUT_JSON=""
BASE_URL_DEFAULT="https://linux-dist.particle.io/releases"
BASE_URL="${BASE_URL_DEFAULT}"

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2;;
    --na-zip)  NA_ZIP="$2";  shift 2;;
    --row-zip) ROW_ZIP="$2"; shift 2;;
    --in)      IN_JSON="$2"; shift 2;;
    --out)     OUT_JSON="$2"; shift 2;;
    --base-url) BASE_URL="$2"; shift 2;;
    -h|--help)
      sed -n '1,30p' "$0"; exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 2;;
  esac
done

# --- Validate ---
[[ -n "$VERSION" ]] || { echo "Missing --version" >&2; exit 2; }
[[ -f "$NA_ZIP"  ]] || { echo "NA zip not found: $NA_ZIP" >&2; exit 2; }
[[ -f "$ROW_ZIP" ]] || { echo "RoW zip not found: $ROW_ZIP" >&2; exit 2; }
[[ -n "$OUT_JSON" ]] || { echo "Missing --out" >&2; exit 2; }

# If input JSON missing, start from empty skeleton
if [[ -z "${IN_JSON}" || ! -f "$IN_JSON" ]]; then
  TMP_IN="$(mktemp)"; echo '{ "builds": [] }' > "$TMP_IN"
else
  TMP_IN="$(mktemp)"; cp "$IN_JSON" "$TMP_IN"
fi

# --- cross-platform sha256 ---
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# --- Derive filenames & SHA ---
NA_FILE="$(basename "$NA_ZIP")"
ROW_FILE="$(basename "$ROW_ZIP")"
NA_SHA="$(sha256 "$NA_ZIP")"
ROW_SHA="$(sha256 "$ROW_ZIP")"

NOW="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
NA_URL="${BASE_URL}/${VERSION}/NA/${NA_FILE}"
ROW_URL="${BASE_URL}/${VERSION}/RoW/${ROW_FILE}"

# --- Build the two 24.04 desktop objects (NA/RoW) ---
NA_JSON="$(jq -n \
  --arg ver "$VERSION" --arg now "$NOW" --arg url "$NA_URL" --arg sha "$NA_SHA" '
  {
    release_name: ("tachyon-ubuntu-24.04-NA-desktop-" + $ver),
    version: $ver,
    region: "NA",
    variant: "desktop",
    platform: "qcm6490",
    board: "formfactor_dvt",
    os: "linux",
    distribution: "ubuntu",
    distribution_version: "24.04",
    distribution_variant: "ubuntu",
    build_date: $now,
    artifacts: [
      { artifact_url: $url, sha256_checksum: $sha, type: "release_image" }
    ]
  }'
)"

ROW_JSON="$(jq -n \
  --arg ver "$VERSION" --arg now "$NOW" --arg url "$ROW_URL" --arg sha "$ROW_SHA" '
  {
    release_name: ("tachyon-ubuntu-24.04-RoW-desktop-" + $ver),
    version: $ver,
    region: "RoW",
    variant: "desktop",
    platform: "qcm6490",
    board: "formfactor_dvt",
    os: "linux",
    distribution: "ubuntu",
    distribution_version: "24.04",
    distribution_variant: "ubuntu",
    build_date: $now,
    artifacts: [
      { artifact_url: $url, sha256_checksum: $sha, type: "release_image" }
    ]
  }'
)"

TMP_OUT="$(mktemp)"

# --- Replace (not append duplicates) for same {version, 24.04, region, variant, board} ---
jq \
  --arg ver "$VERSION" \
  --argjson na  "$NA_JSON" \
  --argjson row "$ROW_JSON" \
  '
  .builds |=
    [ .[]
      | select(
          not (
            .version == $ver
            and .distribution_version == "24.04"
            and (
              (.region == $na.region  and .variant == $na.variant  and .board == $na.board)
              or
              (.region == $row.region and .variant == $row.variant and .board == $row.board)
            )
          )
      )
    ]
  | .builds += [ $na, $row ]
  ' "$TMP_IN" > "$TMP_OUT"

mv "$TMP_OUT" "$OUT_JSON"
echo "Wrote updated metadata -> $OUT_JSON"
echo "Added/updated:"
echo " - ${NA_FILE} (sha256: ${NA_SHA})"
echo " - ${ROW_FILE} (sha256: ${ROW_SHA})"
