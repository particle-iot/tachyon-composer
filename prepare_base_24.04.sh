#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Tachyon System Image Composer – prepare_base_24.04.sh
# -----------------------------------------------------------------------------
# Prepares the 24.04 base directory by unzipping the 20.04 base into
# /tmp/work/output/sys-img-24.04 and ensuring the 20.04 tree is also unpacked
# under /tmp/work/input/sys-img-20.04 for later compose steps.
#
# Env (container paths expected; Makefile should pass them as /tmp/work/...):
#   TMP_OUTPUT_DIR, TMP_INPUT_DIR, BASE24_SYSTEM_IMAGE_DIR
#   BASE20_ZIP, BASE24_IMG, INPUT_BASE_24_04_VERSION, DEBUG
# -----------------------------------------------------------------------------

set -euo pipefail

if [ "${DEBUG:-false}" = "true" ]; then
  set -x
fi

section() {
  echo
  echo "======================================================================="
  echo "==> $*"
  echo "======================================================================="
  echo
}

map_to_container_path() {
  case "$1" in
    ./.tmp/*) echo "/tmp/work/${1#./.tmp/}" ;;
    ./tmp/*)  echo "/tmp/work/${1#./tmp/}"  ;;
    *)        echo "$1" ;;
  esac
}

_err() { echo "ERROR: $*" >&2; exit 1; }

# --- Inputs -------------------------------------------------------------------
TMP_OUTPUT_DIR="$(map_to_container_path "${TMP_OUTPUT_DIR:?TMP_OUTPUT_DIR unset}")"
TMP_INPUT_DIR="$(map_to_container_path "${TMP_INPUT_DIR:?TMP_INPUT_DIR unset}")"
BASE24_SYSTEM_IMAGE_DIR="${BASE24_SYSTEM_IMAGE_DIR:-sys-img-24.04}"
BASE20_ZIP="$(map_to_container_path "${BASE20_ZIP:?BASE20_ZIP unset}")"
BASE24_IMG="$(map_to_container_path "${BASE24_IMG:?BASE24_IMG unset}")"
INPUT_BASE_24_04_VERSION="${INPUT_BASE_24_04_VERSION:-unknown}"
OUTPUT_VERSION="${OUTPUT_VERSION:-unknown}"

BASEDIR="$TMP_OUTPUT_DIR/$BASE24_SYSTEM_IMAGE_DIR"
SRC20_DIR="$TMP_INPUT_DIR/sys-img-20.04"

section "Preparing 24.04 base directory"
echo "Target dir: $BASEDIR"
echo "20.04 zip : $BASE20_ZIP"
echo "24.04 img : $BASE24_IMG"

[ -f "$BASE20_ZIP" ] || _err "20.04 zip not found: $BASE20_ZIP"
mkdir -p "$TMP_OUTPUT_DIR" "$TMP_INPUT_DIR"

# --- Ensure 20.04 is unpacked under /tmp/work/input/sys-img-20.04 ------------
section "Ensuring 20.04 is unpacked under $SRC20_DIR"
if [ -d "$SRC20_DIR/images/qcm6490/edl" ]; then
  echo "20.04 EDL tree already present at $SRC20_DIR"
else
  echo "Unpacking 20.04 into $SRC20_DIR"
  rm -rf "$SRC20_DIR"
  mkdir -p "$SRC20_DIR"

  # Optional listing (only if DEBUG)
  if [ "${DEBUG:-false}" = "true" ]; then
    echo "Archive listing (unzip -Z -1):"
    unzip -Z -1 "$BASE20_ZIP" | sed 's/^/  /' || true
  fi

  ( cd "$SRC20_DIR"
    if [ "${DEBUG:-false}" = "true" ]; then
      unzip -o -v "$BASE20_ZIP"
    else
      unzip -o     "$BASE20_ZIP"
    fi
  )
  # Sanity check
  [ -d "$SRC20_DIR/images/qcm6490/edl" ] || _err "EDL tree missing after unzip: $SRC20_DIR/images/qcm6490/edl"
fi

# --- Now prepare 24.04 output tree -------------------------------------------
section "Unzipping 20.04 into $BASEDIR (24.04 sys-img)"
rm -rf "$BASEDIR"
mkdir -p "$BASEDIR"

# We can rsync from SRC20_DIR (faster) instead of unzipping again:
rsync -a "$SRC20_DIR/" "$BASEDIR/"
# Show top-level
echo "Post-populate top-level:"
ls -la "$BASEDIR" | sed 's/^/  /'

# --- Verify modem firmware region (MD5 checksums) -----------------------------
section "Verifying modem firmware checksums"
NON_HLOS_BIN="$BASEDIR/images/qcm6490/edl/NON-HLOS.bin"
if [ -f "$NON_HLOS_BIN" ]; then
  echo "NON-HLOS.bin MD5: $(md5sum "$NON_HLOS_BIN" | awk '{print $1}')"
  echo "NON-HLOS.bin size: $(stat -c%s "$NON_HLOS_BIN") bytes"

  # Extract and check a few modem files to verify region
  TEMP_MOUNT=$(mktemp -d)
  echo "Extracting sample modem files from NON-HLOS.bin for verification..."
  mcopy -i "$NON_HLOS_BIN" '::/image/modem.b00' "$TEMP_MOUNT/" 2>/dev/null || true
  mcopy -i "$NON_HLOS_BIN" '::/image/modem.mdt' "$TEMP_MOUNT/" 2>/dev/null || true
  mcopy -i "$NON_HLOS_BIN" '::/image/modemr.jsn' "$TEMP_MOUNT/" 2>/dev/null || true

  if [ -f "$TEMP_MOUNT/modem.b00" ]; then
    echo "  modem.b00 MD5: $(md5sum "$TEMP_MOUNT/modem.b00" | awk '{print $1}')"
    echo "  modem.b00 size: $(stat -c%s "$TEMP_MOUNT/modem.b00") bytes"
  fi
  if [ -f "$TEMP_MOUNT/modem.mdt" ]; then
    echo "  modem.mdt MD5: $(md5sum "$TEMP_MOUNT/modem.mdt" | awk '{print $1}')"
    echo "  modem.mdt size: $(stat -c%s "$TEMP_MOUNT/modem.mdt") bytes"
  fi

  rm -rf "$TEMP_MOUNT"
else
  echo "WARNING: NON-HLOS.bin not found at $NON_HLOS_BIN"
fi

# Print which 20.04 zip was used
echo "20.04 source: $(basename "$BASE20_ZIP")"
DETECTED_REGION=$(basename "$BASE20_ZIP" | grep -oP '(NA|RoW)' || echo 'UNKNOWN')
echo "Detected region from filename: $DETECTED_REGION"

# --- Copy the 24.04 .img next to sys-img (optional; not inside) --------------
section "Copying 24.04 .img next to sys-img (optional)"
cp -f "$BASE24_IMG" "$TMP_OUTPUT_DIR/" || true
echo "Placed: $TMP_OUTPUT_DIR/$(basename "$BASE24_IMG")"

# --- Update manifest.json -----------------------------------------------------
section "Updating manifest.json"
MANIFEST="$BASEDIR/manifest.json"
if [ ! -f "$MANIFEST" ]; then
  # if nested, try to locate
  found="$(find "$BASEDIR" -maxdepth 2 -type f -name manifest.json | head -n1 || true)"
  [ -n "$found" ] || _err "manifest.json not found under $BASEDIR"
  if [ "$found" != "$MANIFEST" ]; then
    echo "manifest.json found at $found — moving to $MANIFEST"
    mv "$found" "$MANIFEST"
  fi
fi

now="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
jq --arg now "$now" --arg base24 "$INPUT_BASE_24_04_VERSION" '
  .distribution_version = "24.04"
  | .release_name |= (
      sub("20\\.04"; "24.04")
      | sub("-[0-9]+\\.[0-9]+\\.[0-9]+$"; "-$OUTPUT_VERSION")
    )
  | .version = "$OUTPUT_VERSION"
  | .build_date = $now
  | .sources += [{"key":"ubuntu-24.04","value":$base24}]' \
  "$MANIFEST" > "$MANIFEST.tmp"
echo "Updated manifest.json!"
mv "$MANIFEST.tmp" "$MANIFEST"

section "Prepared"
echo "sys-img dir : $BASEDIR"
echo "manifest    : $MANIFEST"
echo "ls -la $BASEDIR:"
ls -la "$BASEDIR" | sed 's/^/  /'