#!/bin/bash

set -euo pipefail

# Resolve sources relative to this script, so it works regardless of the caller's cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRUB_SRC_DIR="${SCRIPT_DIR}/grub-efi-src-dir/EFI/BOOT"

# 1) Create an empty 512MB image
dd if=/dev/zero of=efi.img bs=1M count=512

# 2) Format as FAT32 with 4K logical sectors for 4Kn target devices
mkfs.vfat -F 32 -S 4096 efi.img

# 3) Populate ESP with GRUB + grub.cfg
mmd -i efi.img ::/EFI ::/EFI/BOOT
mcopy -i efi.img "${GRUB_SRC_DIR}/BOOTAA64.EFI" ::/EFI/BOOT/bootaa64.efi
mcopy -i efi.img "${GRUB_SRC_DIR}/grub.cfg" ::/EFI/BOOT/grub.cfg
