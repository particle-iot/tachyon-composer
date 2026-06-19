#!/bin/bash

set -euo pipefail

dtb_path="${1:-}"
if [[ -z "$dtb_path" ]]; then
  echo "Usage: $0 <dtb-file>" >&2
  exit 1
fi

if [[ ! -f "$dtb_path" ]]; then
  echo "Error: file not found: $dtb_path" >&2
  exit 1
fi

if [[ "${dtb_path##*.}" != "dtb" ]]; then
  echo "Error: not a .dtb file: $dtb_path" >&2
  exit 1
fi

# 1) Create an empty 64MB image
dd if=/dev/zero of=dtb.img bs=1M count=64

# 2) Format as FAT16 with a 4K logical sector (-S 4096), 1 sector/cluster (-s 1).
#    Why FAT16+4K and not FAT32 (dtb_a is 64MB, UFS device sector is 4096):
#    - FAT32+4K: 64MB/4K is only ~16320 clusters, below the FAT32 minimum of
#      65525, so EDK2 FatPkg rejects it (EFI_VOLUME_CORRUPTED) and the board hangs.
#    - FAT32+512B: EDK2 reads it, but BPB sector(512) < device sector(4096) so
#      Linux refuses to mount ("logical sector size too small for device").
#    - FAT16+4K: ~16363 clusters fall in the FAT16 range [4085, 65525), accepted
#      by EDK2; BPB sector(4096) == device sector(4096) so Linux mounts it too.
#    Note: at the fixed 64MB size, -s 1 gives ~16363 clusters (mid FAT16 range).
#    Growing the partition to >=256MB would exceed FAT16's 65525-cluster limit.
mkfs.vfat -F 16 -S 4096 -s 1 dtb.img

# 3) Copy dtb into the image as combined-dtb.dtb
mcopy -i dtb.img "$dtb_path" ::/combined-dtb.dtb
