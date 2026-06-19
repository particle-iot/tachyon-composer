#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Tachyon System Image Composer – 24.04 (new-BP / Quectel r108 / UEFI backend)
# -----------------------------------------------------------------------------
# Runs inside the builder container (-w /project, /tmp/work = ./.tmp).
#
# Builds an EDL-flashable factory image:
#   1) rootfs.ext4 from the 24.04 base .img (composer's normal rootfs)
#   2) efi.img from the vendored GRUB ESP
#   3) apply the tachyon-overlays stack to rootfs.ext4 (installs kernel, etc.)
#   4) dtb.img (qcm6490-tachyon.dtb) + nonhlos-<variant>.img
#   5) assemble with ptool + partition_ext (bootbinaries + system + efi + dtb_a
#      + core_nhlos_a) -> rawprogram*/patch*
#   6) zip the EDL tree
#
# Inputs placed by the Makefile fetch targets under /tmp/work/input:
#   <BASE24_IMG_BASENAME>            24.04 base .img (rootfs source)
#   QCM6490_bootbinaries.zip         bp-fw boot binaries
#   kernel/linux-modules-*.deb       kernel deb (for qcm6490-tachyon.dtb)
# Tools cloned under /tmp/work/tools: tachyon-overlay-tool (+ overlays at $5).
# Vendored backend under /project: build-efi/ build-dtb/ build-nonhlos/ assemble/
#
# Args:
#   $1 BASE24_IMG_BASENAME   $2 OUTPUT_ZIP   $3 NONHLOS_VARIANT(em|na)
#   $4 OVERLAY_STACK         $5 OVERLAY_PATH (container path, has overlays/+stacks/)
#   $6 OVERLAY_ENV (comma KEY=VAL)   $7 DEBUG(true|false)
# -----------------------------------------------------------------------------
set -euo pipefail

PROJ=/project
IN=/tmp/work/input
OUT=/tmp/work/output
OVERLAY_TOOL_DIR=/tmp/work/tools/tachyon-overlay-tool

BASE24="${1:?BASE24_IMG_BASENAME}"
OUTPUT_ZIP="${2:?OUTPUT_ZIP}"
NONHLOS_VARIANT="${3:?NONHLOS_VARIANT}"
OVERLAY_STACK="${4:?OVERLAY_STACK}"
OVERLAY_PATH="${5:?OVERLAY_PATH}"
OVERLAY_ENV="${6:-}"
DEBUG="${7:-false}"
[ "$DEBUG" = "true" ] && set -x

section(){ echo; echo "==================== $* ===================="; }
mkdir -p "$OUT"
work="$(mktemp -d)"

# ---- 1) rootfs.ext4 from the 24.04 base img ---------------------------------
section "1) rootfs.ext4 from 24.04 base ($BASE24)"
IMG="$IN/$BASE24"
[ -f "$IMG" ] || { echo "ERROR: missing $IMG" >&2; exit 1; }

ROOT_MNT="$work/root"; mkdir -p "$ROOT_MNT"
PART_LOOP=""
loopdev="$(sudo losetup -fP --show "$IMG")"
cleanup(){ set +e; sudo umount "$ROOT_MNT" 2>/dev/null; \
  [ -n "$PART_LOOP" ] && sudo losetup -d "$PART_LOOP" 2>/dev/null; \
  sudo losetup -d "$loopdev" 2>/dev/null; }
trap cleanup EXIT

ready=0
for _ in $(seq 1 50); do [ -b "${loopdev}p1" ] && { ready=1; break; }; sleep 0.1; done
if [ "$ready" -eq 0 ]; then
  sudo partx -a "$loopdev" 2>/dev/null || true
  command -v udevadm >/dev/null 2>&1 && sudo udevadm settle 2>/dev/null || true
  for _ in $(seq 1 50); do [ -b "${loopdev}p1" ] && { ready=1; break; }; sleep 0.1; done
fi
if [ "$ready" -eq 1 ]; then
  sudo mount -o ro "${loopdev}p1" "$ROOT_MNT"
else
  echo "INFO: partition nodes absent; offset-based loop mount"
  start=$(sudo sfdisk -J "$loopdev" | python3 -c "import json,sys; print([p['start'] for p in json.load(sys.stdin)['partitiontable']['partitions'] if p['node'].endswith('p1')][0])")
  PART_LOOP=$(sudo losetup -f --show -o "$((start*512))" "$IMG")
  sudo mount -o ro "$PART_LOOP" "$ROOT_MNT"
fi

used_kb=$(df -k "$ROOT_MNT" | tail -1 | awk '{print $3}')
size=$(( used_kb*1024 + 6*1024*1024*1024 ))     # +6GB headroom: overlay installs a full 1058 kernel
                                                # alongside the base's 1056 kernel (dual modules/headers)
                                                # plus deps; system partition is 10GB so this fits.
size=$(( ((size+4095)/4096)*4096 ))
label=$(sudo blkid -s LABEL -o value "${loopdev}p1" 2>/dev/null || true)
uuid=$(sudo blkid -s UUID  -o value "${loopdev}p1" 2>/dev/null || true)
[ -z "$label" ] && [ -n "$PART_LOOP" ] && label=$(sudo blkid -s LABEL -o value "$PART_LOOP" 2>/dev/null || true)
[ -z "$uuid" ]  && [ -n "$PART_LOOP" ] && uuid=$(sudo blkid -s UUID  -o value "$PART_LOOP" 2>/dev/null || true)

ROOTFS="$OUT/rootfs.ext4"
echo "INFO: rootfs size=$size label=${label:-rootfs} uuid=${uuid:-<gen>}"
truncate -s "$size" "$ROOTFS"
UU=(); [ -n "$uuid" ] && UU=(-U "$uuid")
sudo mkfs.ext4 -q -F -b 4096 -L "${label:-rootfs}" "${UU[@]}" -d "$ROOT_MNT" "$ROOTFS"
sudo umount "$ROOT_MNT"; cleanup; trap - EXIT
echo "OK: $ROOTFS"

# ---- 2) efi.img (vendored GRUB) ---------------------------------------------
section "2) efi.img (vendored GRUB)"
( cd "$PROJ/build-efi" && ./make-efi-img.sh && mv -f efi.img "$OUT/efi.img" )
echo "OK: $OUT/efi.img"

# ---- 3) apply tachyon-overlays stack to rootfs.ext4 (composer normal path) --
section "3) overlay stack: $OVERLAY_STACK"
# run-overlay.sh operates directly on the bare rootfs ext4 (-f). make apply's
# inplace mode instead expects a full sys-img directory (it looks for
# images/qcm6490/edl/qti-...sysfs_1.ext4), which the new-BP path does not have.
RES_DIR="$work/overlay-resources"; mkdir -p "$RES_DIR"     # no extra resources needed
ENV_OPT=(); [ -n "$OVERLAY_ENV" ] && ENV_OPT=(-e "$OVERLAY_ENV")
( cd "$OVERLAY_TOOL_DIR" && bash ./run-overlay.sh \
    -f "$ROOTFS" \
    -r "$RES_DIR" \
    -s "$OVERLAY_STACK" \
    -O "$OVERLAY_PATH" \
    -E "$OUT/efi.img" \
    -d "$DEBUG" \
    "${ENV_OPT[@]}" ) || { echo "ERROR: overlay apply failed" >&2; exit 1; }
echo "OK: overlay applied to $ROOTFS"

# ---- 4) dtb.img + nonhlos-<variant>.img -------------------------------------
section "4) dtb.img (qcm6490-tachyon.dtb)"
"$PROJ/build-dtb/build-dtb.sh" "$IN/kernel" "$OUT/dtb.img"
section "4) nonhlos.img (variant=$NONHLOS_VARIANT)"
"$PROJ/build-nonhlos/make-nonhlos_img.sh" --variant "$NONHLOS_VARIANT" --output "$OUT/nonhlos.img"
echo "OK: $OUT/nonhlos.img"

# ---- 5) assemble (ptool + partition_ext) ------------------------------------
section "5) assemble factory image (ptool)"
"$PROJ/assemble/make_factory_img.sh" \
  --bootbinaries "$IN/QCM6490_bootbinaries.zip" \
  --system       "$ROOTFS" \
  --dtb_a        "$OUT/dtb.img" \
  --efi          "$OUT/efi.img" \
  --core_nhlos_a "$OUT/nonhlos.img" \
  --output       "$OUT/factory"

# ---- 6) package -------------------------------------------------------------
section "6) package -> $OUTPUT_ZIP"
rm -f "$OUT/$OUTPUT_ZIP"
( cd "$OUT/factory" && zip -rq "$OUT/$OUTPUT_ZIP" . )
echo "DONE: $OUT/$OUTPUT_ZIP"
ls -lh "$OUT/$OUTPUT_ZIP"
