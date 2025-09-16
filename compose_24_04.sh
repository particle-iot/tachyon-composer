#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Tachyon System Image Composer – 24.04
# -----------------------------------------------------------------------------
# Purpose:
#   Compose a 24.04 system image by:
#     1) Patching + signing xbl.elf and updating XML sizes
#     2) Extracting ADSP blobs **only from 20.04** EDL rootfs
#     3) Building a new rootfs.ext4 and EFI image from the 24.04 base image
#     4) Swapping the new artifacts into the 24.04 EDL tree + updating XML
#
# Inputs (positional):
#   $1 UBOOT_DIR                 (e.g. "u-boot", dir inside /tmp/work/input/)
#   $2 BASE24_IMG_BASENAME       (e.g. "tachyon-ubuntu-24.04-desktop-image-14-276cd6b.img")
#   $3 BASE24_SYSTEM_IMAGE_DIR   (default: "sys-img-24.04")
#   $4 OUTPUT_24_04_SYSTEM_IMAGE (e.g. "tachyon-ubuntu-24.04-desktop-1.0.0.zip")
#   $5 DEBUG (false or true)
#
# Expected paths in the Docker workspace:
#   /tmp/work/input/$UBOOT_DIR/u-boot-dtb.bin
#   /tmp/work/input/$BASE24_IMG_BASENAME
#   /tmp/work/output/$BASE24_SYSTEM_IMAGE_DIR/images/qcm6490/edl
#   /tmp/work/input/sys-img-20.04/images/qcm6490/edl     (for ADSP extraction)
#
# Outputs (written into the 24.04 EDL directory):
#   - xbl.elf (patched + signed)
#   - qti-ubuntu-robotics-image-qcs6490-odk-sysfs_1.ext4  (new rootfs)
#   - efi.img                                             (new EFI image)
#
# Notes:
#   - Robust mounting: if /dev/loopXpY nodes are not created in the container,
#     we fall back to per‑partition loop devices created with losetup offsets.
# -----------------------------------------------------------------------------

set -euo pipefail

#if degug is true, enable bash debug output
DEBUG="${5:-false}"
if [ "$DEBUG" = "true" ]; then
  set -o xtrace
  set -x
fi

# ---------- Nice section banners ----------
section() {
  echo
  echo "======================================================================="
  echo "==> $*"
  echo "======================================================================="
  echo
}

# ---------- Trim helper ----------

# Helper: trim leading/trailing whitespace
trim() {
  # portable way: use awk to collapse extra spaces
  printf '%s' "$1" | awk '{$1=$1; print}'
}

# ---------- Uniform error reporting ----------
on_error() {
  local ec=$?
  echo
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  echo "ERROR: Command failed (exit $ec): $BASH_COMMAND"
  echo "Working dir: $(pwd)"
  echo "User: $(id -u -n) (uid=$(id -u)), groups: $(id -Gn)"
  echo "Kernel: $(uname -a)"
  echo "losetup -a:"
  sudo losetup -a || true
  echo "lsblk (all):"
  lsblk -o NAME,MAJ:MIN,SIZE,TYPE,MOUNTPOINT,FSTYPE,LABEL || true
  echo "Mounts (grep deps):"
  mount | grep -E '/tmp/deps|/tmp/work' || true
  echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  exit $ec
}
trap on_error ERR

# ---------- Args ----------
section "0) ARGUMENTS & PREFLIGHT"

# Print all args in-order (do NOT use BASH_ARGV here)
echo "Script: $0"
i=1
for a in "$@"; do
  printf "  Arg %d: %s\n" "$i" "$a"
  i=$((i+1))
done

UBOOT_DIR="${1:?missing arg1 (UBOOT_DIR)}"
BASE24_IMG_BASENAME="${2:?missing arg2 (BASE24_IMG_BASENAME)}"
BASE24_SYSTEM_IMAGE_DIR="${3:?missing arg3 (BASE24_SYSTEM_IMAGE_DIR)}"
OUTPUT_24_04_SYSTEM_IMAGE="${4:?missing arg4 (OUTPUT_24_04_SYSTEM_IMAGE)}"
OVERLAY_DEBUG="${5:?missing arg5 (DEBUG)}"             # reuse for overlay too
OVERLAY_ENV="${6:-}"                                   # optional (comma-separated KEY=VAL)
INPUT_OVERLAY_PATH="${7:?missing arg7 (INPUT_OVERLAY_PATH)}"

echo "UBOOT_DIR                 : $UBOOT_DIR"
echo "BASE24_IMG_BASENAME       : $BASE24_IMG_BASENAME"
echo "BASE24_SYSTEM_IMAGE_DIR   : $BASE24_SYSTEM_IMAGE_DIR"
echo "OUTPUT_24_04_SYSTEM_IMAGE : $OUTPUT_24_04_SYSTEM_IMAGE"

#create the final location for the system image 
OUTPUT_24_04_SYSTEM_IMAGE_FULLPATH="/tmp/work/output/$OUTPUT_24_04_SYSTEM_IMAGE"

# Validate inputs exist
[ -n "$UBOOT_DIR" ] || { echo "Error: Missing UBOOT_DIR"; exit 1; }
[ -n "$BASE24_IMG_BASENAME" ] || { echo "Error: Missing BASE24_IMG_BASENAME"; exit 1; }
[ -d "/tmp/work/output/$BASE24_SYSTEM_IMAGE_DIR" ] || { echo "Error: Missing /tmp/work/output/$BASE24_SYSTEM_IMAGE_DIR"; exit 1; }
[ -f "/tmp/work/input/$BASE24_IMG_BASENAME" ] || { echo "Error: Missing /tmp/work/input/$BASE24_IMG_BASENAME"; exit 1; }

# Tools
QTOOLS_DIR=/tmp/work/tools/qtestsign
[ -f "$QTOOLS_DIR/patchxbl.py" ] || { echo "Missing $QTOOLS_DIR/patchxbl.py"; exit 1; }
[ -f "$QTOOLS_DIR/qtestsign.py" ] || { echo "Missing $QTOOLS_DIR/qtestsign.py"; exit 1; }
[ -f "./xml_tools.py" ] || { echo "Missing ./xml_tools.py"; exit 1; }

echo "INFO: Input image size: $(stat -c%s "/tmp/work/input/$BASE24_IMG_BASENAME") bytes"

# ---------- Layout preparation ----------
section "1) LAYOUT PREPARATION"

DEPS_DIR="/tmp/deps"
mkdir -p "$DEPS_DIR"
mkdir -p "$DEPS_DIR/particle-iot-inc/tachyon-u-boot" \
         "$DEPS_DIR/image/mount" \
         "$DEPS_DIR/image/adsp" \
         "$DEPS_DIR/particle-iot-inc/tachyon-ubuntu-24.04" \
         "$DEPS_DIR/image"

# Symlink to expected unpacked dirs
rm -f "$DEPS_DIR/image/unpacked_20_04" "$DEPS_DIR/image/unpacked_24_04"
ln -sfn /tmp/work/output/sys-img-24.04 "$DEPS_DIR/image/unpacked_24_04"
ln -sfn /tmp/work/input/sys-img-20.04 "$DEPS_DIR/image/unpacked_20_04"

EDL_20_04_PATH="$DEPS_DIR/image/unpacked_20_04/images/qcm6490/edl"
EDL_24_04_PATH="$DEPS_DIR/image/unpacked_24_04/images/qcm6490/edl"
echo "Using EDL_20_04_PATH: $EDL_20_04_PATH"
echo "Using EDL_24_04_PATH: $EDL_24_04_PATH"

[ -d "$EDL_20_04_PATH" ] || { echo "Error: Expected $EDL_20_04_PATH (check 20.04 base zip contents)"; exit 1; }
[ -d "$EDL_24_04_PATH" ] || { echo "Error: Expected $EDL_24_04_PATH (check 24.04 base zip contents)"; exit 1; }

echo "INFO: rawprogram files (24.04):"
ls -1 "$EDL_24_04_PATH"/rawprogram1.xml \
      "$EDL_24_04_PATH"/rawprogram2.xml \
      "$EDL_24_04_PATH"/rawprogram3.xml \
      "$EDL_24_04_PATH"/rawprogram4.xml \
      "$EDL_24_04_PATH"/rawprogram5.xml \
      "$EDL_24_04_PATH"/rawprogram6.xml \
      "$EDL_24_04_PATH"/rawprogram_unsparse0.xml

# ---------- Replace bootloader ----------
section "2) REPLACE BOOTLOADER (patch + sign + XML size update)"

"$QTOOLS_DIR/patchxbl.py" \
  -o "$EDL_24_04_PATH/xbl_patched.elf" \
  -c "/tmp/work/input/$UBOOT_DIR/u-boot-dtb.bin" \
  "$EDL_24_04_PATH/xbl.elf"

"$QTOOLS_DIR/qtestsign.py" -v6 abl \
  -o "$EDL_24_04_PATH/xbl.elf" \
  "$EDL_24_04_PATH/xbl_patched.elf"

rm -f "$EDL_24_04_PATH/xbl_patched.elf"

# Update xbl size in rawprogram1/2
xbl_size=$(stat --printf="%s" "$EDL_24_04_PATH/xbl.elf")
xbl_size=$(( ((xbl_size + 4095) / 4096) * 4096 ))  # 4KiB align
xbl_size=$(( xbl_size / 1024 ))                    # in KiB
python3 "./xml_tools.py" modify --input "$EDL_24_04_PATH/rawprogram1.xml" --label "xbl_a" --field "size_in_KB" --value "${xbl_size}.0" || true
python3 "./xml_tools.py" modify --input "$EDL_24_04_PATH/rawprogram2.xml" --label "xbl_b" --field "size_in_KB" --value "${xbl_size}.0" || true

# ---------- Extract ADSP (20.04 only, per request) ----------
section "3) EXTRACT ADSP BLOBS from 20.04 ROOTFS"

found_adsp=0
mkdir -p "$DEPS_DIR/image/adsp"

rootfs_ext4=$(ls "$EDL_20_04_PATH"/qti-ubuntu-robotics-image-*-sysfs_1.ext4 2>/dev/null | head -n1 || true)
if [ -z "$rootfs_ext4" ]; then
  echo "Warning: 20.04 rootfs ext4 not found in $EDL_20_04_PATH – skipping ADSP extraction"
else
  echo "INFO: Mounting rootfs ext4 from: $rootfs_ext4"
  sudo mount -o loop,ro "$rootfs_ext4" "$DEPS_DIR/image/mount"

  adsp_src_dir=""
  for d in "$DEPS_DIR/image/mount/usr/lib/firmware" "$DEPS_DIR/image/mount/lib/firmware"; do
    if compgen -G "$d/adsp*" >/dev/null; then
      adsp_src_dir="$d"
      break
    fi
  done

  if [ -n "$adsp_src_dir" ]; then
    shopt -s nullglob
    files=( "$adsp_src_dir"/adsp* )
    shopt -u nullglob
    if [ ${#files[@]} -gt 0 ]; then
      echo "Copying ${#files[@]} ADSP blobs from $adsp_src_dir (EDL: $EDL_20_04_PATH)"
      sudo rsync -a "${files[@]}" "$DEPS_DIR/image/adsp/"
      found_adsp=1
    fi
  else
    echo "Warning: no adsp* firmware found under /usr/lib/firmware or /lib/firmware in 20.04 rootfs"
  fi

  sudo umount "$DEPS_DIR/image/mount"
fi

# ---------- Replace rootfs & build EFI (single pass; offset‑mount aware) ----------
section "4) REPLACE ROOTFS & BUILD NEW EFI IMAGE"

mkdir -p "$DEPS_DIR/particle-iot-inc/tachyon-ubuntu-24.04/root" \
         "$DEPS_DIR/particle-iot-inc/tachyon-ubuntu-24.04/efi"

echo "INFO: Attaching loop device for /tmp/work/input/$BASE24_IMG_BASENAME"
loopdev=$(sudo losetup -fP --show "/tmp/work/input/$BASE24_IMG_BASENAME")
echo "INFO: loopdev: $loopdev"
sudo losetup -a | grep -F "$loopdev" || true

# Clean up resources on exit
PART_LOOP_P1=""
PART_LOOP_P15=""
cleanup() {
  set +e
  sudo umount "$DEPS_DIR/image/mount"                                   2>/dev/null || true
  sudo umount "$DEPS_DIR/particle-iot-inc/tachyon-ubuntu-24.04/root"    2>/dev/null || true
  sudo umount "$DEPS_DIR/particle-iot-inc/tachyon-ubuntu-24.04/efi"     2>/dev/null || true
  [ -n "${PART_LOOP_P1:-}" ] && sudo losetup -d "$PART_LOOP_P1"          2>/dev/null || true
  [ -n "${PART_LOOP_P15:-}" ] && sudo losetup -d "$PART_LOOP_P15"        2>/dev/null || true
  for p in "${loopdev}"p*; do
    [ -e "$p" ] && sudo umount "$p"                                      2>/dev/null || true
  done
  sudo losetup -d "$loopdev"                                             2>/dev/null || true
  sudo losetup -D                                                        2>/dev/null || true
}
trap cleanup EXIT

# Try to wait for partition nodes to appear; nudge udev and partx if needed
partitions_ready=0
for i in $(seq 1 50); do
  if [ -b "${loopdev}p1" ] && [ -b "${loopdev}p15" ]; then
    partitions_ready=1
    break
  fi
  sleep 0.1
done

if [ $partitions_ready -eq 0 ]; then
  echo "INFO: p1/p15 not visible yet; attempting 'partx -a $loopdev'"
  sudo partx -a "$loopdev" || true
  command -v udevadm >/dev/null 2>&1 && sudo udevadm settle || true

  for i in $(seq 1 80); do
    if [ -b "${loopdev}p1" ] && [ -b "${loopdev}p15" ]; then
      partitions_ready=1
      break
    fi
    sleep 0.1
  done
fi

echo "DEBUG: After wait -> /dev entries:"
ls -l "$loopdev" || true

USE_OFFSET_MOUNT=0
if [ $partitions_ready -ne 1 ]; then
  echo "WARN: /dev/* partition nodes not present after wait; using offset-based mounts."
  USE_OFFSET_MOUNT=1
fi

# Helper to get partition start in sectors via sfdisk/jq
get_part_start_sectors() {
  local dev="$1" part="$2" start=
  command -v sfdisk >/dev/null 2>&1 || { echo "ERROR: sfdisk not available"; exit 1; }
  command -v jq     >/dev/null 2>&1 || { echo "ERROR: jq not available"; exit 1; }
  start=$(sudo sfdisk -J "$dev" | jq -r --arg p "$part" '.partitiontable.partitions[] | select(.node|endswith($p)) | .start')
  [ -n "$start" ] || { echo "ERROR: could not read start sector for $dev ($part)"; exit 1; }
  echo "$start"
}

# Mount root/EFI from 24.04 image
if [ $USE_OFFSET_MOUNT -eq 0 ]; then
  sudo mount "${loopdev}p1"  "$DEPS_DIR/particle-iot-inc/tachyon-ubuntu-24.04/root"
  sudo mount "${loopdev}p15" "$DEPS_DIR/particle-iot-inc/tachyon-ubuntu-24.04/efi"
else
  p1_start=$(get_part_start_sectors "$loopdev" "p1")
  p15_start=$(get_part_start_sectors "$loopdev" "p15")
  p1_off=$(( p1_start * 512 ))
  p15_off=$(( p15_start * 512 ))
  echo "INFO: p1_start=$p1_start (offset=$p1_off), p15_start=$p15_start (offset=$p15_off)"

  PART_LOOP_P1=$(sudo losetup -f --show -o "$p1_off" "/tmp/work/input/$BASE24_IMG_BASENAME")
  PART_LOOP_P15=$(sudo losetup -f --show -o "$p15_off" "/tmp/work/input/$BASE24_IMG_BASENAME")
  echo "INFO: Using offset loops -> P1:$PART_LOOP_P1  P15:$PART_LOOP_P15"

  sudo mount -o ro "$PART_LOOP_P1"  "$DEPS_DIR/particle-iot-inc/tachyon-ubuntu-24.04/root"
  sudo mount -o ro "$PART_LOOP_P15" "$DEPS_DIR/particle-iot-inc/tachyon-ubuntu-24.04/efi"
fi

# Create new root.ext4 sized to the full 24.04 disk image (4KiB aligned)
rootfs_size=$(stat --printf="%s" "/tmp/work/input/$BASE24_IMG_BASENAME")
rootfs_size=$(( ((rootfs_size + 4095) / 4096) * 4096 ))
echo "INFO: rootfs_size (aligned): $rootfs_size bytes"
truncate -s "$rootfs_size" "$DEPS_DIR/image/root.ext4"

# Carry over LABEL/UUID if available; otherwise fallback
label=$(sudo blkid -s LABEL -o value "${loopdev}p1" || true)
uuid=$(sudo blkid -s UUID  -o value "${loopdev}p1" || true)

# Add this to pick up values when using offset loops:
if [ -z "$label" ] && [ -n "${PART_LOOP_P1:-}" ]; then
  label=$(sudo blkid -s LABEL -o value "$PART_LOOP_P1" || true)
fi
if [ -z "$uuid" ] && [ -n "${PART_LOOP_P1:-}" ]; then
  uuid=$(sudo blkid -s UUID  -o value "$PART_LOOP_P1" || true)
fi

: "${label:=desktop-rootfs}"
: "${uuid:=00000000-0000-4000-8000-000000000000}"

# And for EFI label (just before mkfs.vfat):
efi_label=$(sudo blkid -s LABEL -o value "${loopdev}p15" || true)
if [ -z "$efi_label" ] && [ -n "${PART_LOOP_P15:-}" ]; then
  efi_label=$(sudo blkid -s LABEL -o value "$PART_LOOP_P15" || true)
fi
: "${efi_label:=UEFI}"

echo "INFO: rootfs label=$label uuid=$uuid"

sudo mkfs.ext4 -q -F -b 4096 -L "$label" -U "$uuid" \
  -d "$DEPS_DIR/particle-iot-inc/tachyon-ubuntu-24.04/root" \
  "$DEPS_DIR/image/root.ext4"

# Add ADSP blobs into the new rootfs (if we found any in 20.04)
sudo mount -o loop "$DEPS_DIR/image/root.ext4" "$DEPS_DIR/image/mount"
sudo mkdir -p "$DEPS_DIR/image/mount/lib/firmware/updates/tachyon"
if compgen -G "$DEPS_DIR/image/adsp/*" > /dev/null; then
  sudo cp "$DEPS_DIR/image/adsp/"* "$DEPS_DIR/image/mount/lib/firmware/updates/tachyon/"
fi
sudo umount "$DEPS_DIR/image/mount"

# Pick the rawprogram file that defines boot_a (fallback to any rawprogram*.xml)
boot_xml=$(grep -l 'label="boot_a"' "$EDL_24_04_PATH"/rawprogram*.xml | head -n1 || true)
[ -n "$boot_xml" ] || boot_xml=$(ls "$EDL_24_04_PATH"/rawprogram*.xml 2>/dev/null | head -n1 || true)

# Create EFI image sized per XML's num_partition_sectors * 4096
efi_sectors=$(xmllint --xpath "string(//program[@label='boot_a']/@num_partition_sectors)" "$boot_xml" 2>/dev/null || true)
[ -n "$efi_sectors" ] || { echo "Error: could not read num_partition_sectors for boot_a from $boot_xml"; exit 1; }
efi_size=$((efi_sectors * 4096))
echo "INFO: EFI image size from XML: $efi_size bytes"

truncate -s "$efi_size" "$DEPS_DIR/image/efi.img"
efi_label=$(sudo blkid -s LABEL -o value "${loopdev}p15" || true)
: "${efi_label:=UEFI}"
sudo mkfs.vfat -F 16 -s 1 -S 4096 -n "$efi_label" "$DEPS_DIR/image/efi.img"

# Populate EFI from mounted 24.04 EFI partition
sudo mount -o loop "$DEPS_DIR/image/efi.img" "$DEPS_DIR/image/mount"
sudo rsync -aHAX "$DEPS_DIR/particle-iot-inc/tachyon-ubuntu-24.04/efi/" "$DEPS_DIR/image/mount/"
sudo umount "$DEPS_DIR/image/mount"

# Swap in new rootfs + EFI and update XML sizes/filenames
sudo rm -f "$EDL_24_04_PATH/qti-ubuntu-robotics-image-qcs6490-odk-sysfs_1.ext4"
sudo mv "$DEPS_DIR/image/root.ext4" "$EDL_24_04_PATH/qti-ubuntu-robotics-image-qcs6490-odk-sysfs_1.ext4"

python3 ./xml_tools.py modify \
  --input "$EDL_24_04_PATH/rawprogram_unsparse0.xml" \
  --label "system_a" \
  --field "num_partition_sectors" \
  --value "$((rootfs_size / 4096))"

sudo mv "$DEPS_DIR/image/efi.img" "$EDL_24_04_PATH/efi.img"
python3 ./xml_tools.py modify --input "$boot_xml" --label "boot_a" --field "filename" --value "efi.img"
python3 ./xml_tools.py modify --input "$boot_xml" --label "boot_b" --field "filename" --value "efi.img"

# ---------- APPLY OVERLAYS to the freshly built ext4 --------------------------
# section "5) APPLY OVERLAYS"

# # The sys-img directory we just populated (this is what the overlay expects)
# SYSDIR="/tmp/work/output/${BASE24_SYSTEM_IMAGE_DIR:-sys-img-24.04}"

# # Path to the tachyon-overlay tool inside the container (adjust if different)
# OVERLAY_TOOL_DIR="/tmp/work/tools/tachyon-overlay"

# # Required inputs for the overlay
# # - INPUT_OVERLAY_PATH must point to a dir (or colon-separated dirs)
# #   that contain 'overlays/' and 'stacks/' subfolders INSIDE THE CONTAINER.
# #   (Avoid host paths like /Users/... unless you bind-mounted them.)
# : "${INPUT_OVERLAY_PATH:?ERROR: set INPUT_OVERLAY_PATH to your overlays root(s), e.g. /project/tachyon-release-builder}"
# : "${INPUT_OVERLAY_STACK:=ubuntu-headless-24.04}"     # override if you want a different stack
# : "${OVERLAY_DEBUG:=${DEBUG:-false}}"           # reuse compose DEBUG unless overridden

# OVERLAY_DEBUG="$(trim "$OVERLAY_DEBUG")"
# OVERLAY_ENV="$(trim "$OVERLAY_ENV")"
# INPUT_OVERLAY_PATH="$(trim "$INPUT_OVERLAY_PATH")"
# INPUT_OVERLAY_STACK="$(trim "$INPUT_OVERLAY_STACK")"

# # Optional env pins passed to overlay (comma-separated KEY=VAL)
# # Example:
# #   OVERLAY_ENV='PKG_particle_linux=0.20.1-1,PKG_particle_tachyon_desktop_setup=2.7.0,PIN_PRIORITY=900'

# # Run the overlay in-place (no OUTPUT_SYSTEM_IMAGE) so packaging below zips the final tree
# pushd "$OVERLAY_TOOL_DIR" >/dev/null
#   echo "==> Running tachyon-overlay on $SYSDIR (stack: $INPUT_OVERLAY_STACK)"
#   make apply \
#     INPUT_OVERLAY_PATH="$INPUT_OVERLAY_PATH" \
#     INPUT_STACK_NAME="$INPUT_OVERLAY_STACK" \
#     INPUT_SYSTEM_IMAGE="$SYSDIR" \
#     DEBUG="$OVERLAY_DEBUG" \
#     $( [ -n "$OVERLAY_ENV" ] && printf "%s" "INPUT_ENV_VARS=$INPUT_ENV" )
# popd >/dev/null

###########################################################################
# Package final system image (zip the prepared BASE24_SYSTEM_IMAGE_DIR)
###########################################################################
section "PACKAGE SYSTEM IMAGE (ZIP)"

# Where the sys-img directory lives (in our build layout it’s under /tmp/work/output)
SYSDIR="/tmp/work/output/${BASE24_SYSTEM_IMAGE_DIR:-sys-img-24.04}"

if [ ! -d "$SYSDIR" ]; then
  echo "ERROR: packaging directory not found: $SYSDIR" >&2
  exit 1
fi

echo "  Packaging $SYSDIR -> $OUTPUT_24_04_SYSTEM_IMAGE_FULLPATH"

# Include dotfiles by zipping from within the dir
COMPRESSION_FACTOR=3

#if we are in debug, reduce to compression 1
if [ "$DEBUG" = "true" ]; then
  COMPRESSION_FACTOR=1
fi

( cd "$SYSDIR" && zip -r -"$COMPRESSION_FACTOR" -v "$OUTPUT_24_04_SYSTEM_IMAGE_FULLPATH" . )

# ---------- Completed ----------
section "COMPLETED"
echo "EDL 24.04 path     : $EDL_24_04_PATH"
echo "Rootfs output      : $EDL_24_04_PATH/qti-ubuntu-robotics-image-qcs6490-odk-sysfs_1.ext4"
echo "EFI output         : $EDL_24_04_PATH/efi.img"
echo "Package output     : $OUTPUT_24_04_SYSTEM_IMAGE_FULLPATH"
echo "==> Compose 24.04 image: completed."
