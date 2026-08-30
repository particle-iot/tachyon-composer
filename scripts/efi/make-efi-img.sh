#!/bin/bash

set -euo pipefail

# Resolve sources relative to this script, so it works regardless of the caller's cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRUB_SRC_DIR="${SCRIPT_DIR}/grub-efi-src-dir/EFI/BOOT"
PARTITION_XML="${SCRIPT_DIR}/../assemble/config/partition_ext.xml"

# 0) Check that grub's root= names a partition that actually exists.
#
# root=/dev/sdaN is the failure this guards against: partition indices shift
# whenever anything is added ahead of them. Adding misc to LUN 0 moved system
# from sda3 to sda4, and the stale root=/dev/sda3 handed the kernel a 1MiB
# partition with no filesystem -- the board flashed cleanly, then stopped in
# initramfs with "No init found". Nothing in the build noticed, because nothing
# checked. A label does not move, so index-based roots are rejected outright and
# a label-based one must match the partition table shipped beside it.
check_grub_root() {
  local cfg="${GRUB_SRC_DIR}/grub.cfg"
  [ -r "$cfg" ] || { echo "ERROR: cannot read $cfg" >&2; exit 1; }

  local root
  root="$(grep -oE 'root=[^[:space:]]+' "$cfg" | head -1 || true)"
  [ -n "$root" ] || { echo "ERROR: no root= in $cfg" >&2; exit 1; }

  case "$root" in
    root=/dev/*)
      echo "ERROR: $cfg uses '$root'." >&2
      echo "       Device-node roots break whenever the partition table changes." >&2
      echo "       Use root=PARTLABEL=<label> instead." >&2
      exit 1
      ;;
    root=PARTLABEL=*)
      local label="${root#root=PARTLABEL=}"
      [ -r "$PARTITION_XML" ] || {
        echo "ERROR: cannot read $PARTITION_XML to verify '$root'" >&2; exit 1; }
      if ! grep -q "label=\"${label}\"" "$PARTITION_XML"; then
        echo "ERROR: $cfg boots root=PARTLABEL=${label}, but no partition with" >&2
        echo "       label=\"${label}\" exists in $PARTITION_XML." >&2
        exit 1
      fi
      echo "OK: grub root=PARTLABEL=${label} matches a partition in the table"
      ;;
    *)
      echo "ERROR: $cfg uses '$root', which is neither a device node nor a" >&2
      echo "       PARTLABEL. Refusing to ship a root= this script cannot verify." >&2
      exit 1
      ;;
  esac
}
check_grub_root

# 1) Create an empty 512MB image
dd if=/dev/zero of=efi.img bs=1M count=512

# 2) Format as FAT32 with 4K logical sectors for 4Kn target devices
mkfs.vfat -F 32 -S 4096 efi.img

# 3) Populate ESP with GRUB + grub.cfg
mmd -i efi.img ::/EFI ::/EFI/BOOT
mcopy -i efi.img "${GRUB_SRC_DIR}/BOOTAA64.EFI" ::/EFI/BOOT/bootaa64.efi
mcopy -i efi.img "${GRUB_SRC_DIR}/grub.cfg" ::/EFI/BOOT/grub.cfg
