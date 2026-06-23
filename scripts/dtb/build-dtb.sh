#!/usr/bin/env bash
# build-dtb: extract the Tachyon board device tree from the kernel deb(s) and
# package it into dtb.img (64MB FAT16) via make-dtb-img.sh.
#
# IMPORTANT: use the single-board qcm6490-tachyon.dtb, NOT the kernel's
# combined-dtb.dtb. combined-dtb.dtb is a `cat` of unrelated reference boards'
# *-ovl.dtb (RB3gen2 / qcs5430 / IQ EVK / ...) and contains NO Tachyon node.
# UEFI/EDK2 reads dtb_a by the fixed filename "combined-dtb.dtb"; make-dtb-img.sh
# writes our qcm6490-tachyon.dtb under that name.
#
# Needs kernel >= stable-6.8.0-1058.59particle2 (first release whose deb ships
# qcm6490-tachyon.dtb; PR particle-iot/tachyon-ubuntu-24.04-kernel#29).
#
# Usage: build-dtb.sh <kernel-deb-dir> <output-dtb-img>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEB_DIR="${1:?usage: build-dtb.sh <kernel-deb-dir> <output-dtb-img>}"
OUT_IMG="${2:?usage: build-dtb.sh <kernel-deb-dir> <output-dtb-img>}"

for c in dpkg-deb mkfs.vfat mcopy; do
  command -v "$c" >/dev/null 2>&1 || { echo "[ERROR] missing command: $c" >&2; exit 1; }
done

ls "${DEB_DIR}"/linux-*.deb >/dev/null 2>&1 \
  || { echo "[ERROR] no kernel deb in ${DEB_DIR}" >&2; exit 1; }

work="$(mktemp -d)"; trap 'rm -rf "${work}"' EXIT
# dtb may live in linux-image or linux-modules; unpack all (skip headers) and search
for deb in "${DEB_DIR}"/linux-*.deb; do
  case "$(basename "${deb}")" in *linux-headers*) continue ;; esac
  dpkg-deb -x "${deb}" "${work}/deb" 2>/dev/null || true
done

dtb="$(find "${work}/deb" -name 'qcm6490-tachyon.dtb' | head -1)"
[ -n "${dtb}" ] \
  || { echo "[ERROR] qcm6490-tachyon.dtb not found in kernel debs (need kernel >= stable-6.8.0-1058.59particle2)" >&2; exit 1; }
echo "[INFO] dtb: ${dtb}"

# make-dtb-img.sh writes dtb.img into its CWD; produce it in a temp CWD then move.
OUT_IMG_ABS="$(cd "$(dirname "${OUT_IMG}")" && pwd)/$(basename "${OUT_IMG}")"
( cd "${work}" && "${SCRIPT_DIR}/make-dtb-img.sh" "${dtb}" && mv -f dtb.img "${OUT_IMG_ABS}" )
echo "[OK] ${OUT_IMG_ABS}"
