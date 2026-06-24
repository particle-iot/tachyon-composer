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
#   5) SIGN the boot/firmware blobs from bp-fw (selectable key) — composer-owned
#   6) assemble with ptool + partition_ext (signed bootbinaries + system + efi
#      + dtb_a + core_nhlos_a) -> rawprogram*/patch*
#   7) manifest.json + zip
#
# Unlike the legacy 20.04 path there is NO 20.04 base, NO U-Boot patch and NO
# qtestsign: every component enters UNSIGNED and the composer signs it here via
# scripts/signing/ with a selectable key (see scripts/signing/README.md, keys/).
#
# Inputs placed by the Makefile fetch targets under /tmp/work/input:
#   <BASE24_IMG_BASENAME>            24.04 base .img (rootfs source)
#   QCM6490_bootbinaries.zip         bp-fw boot binaries (sign-ready when built from feature/nosign)
#   kernel/linux-modules-*.deb       kernel deb (for qcm6490-tachyon.dtb)
# Tools cloned under /tmp/work/tools: tachyon-overlay-tool (+ overlays at $5).
# Vendored under /project: scripts/{efi,dtb,assemble,signing}/ keys/
# (nonhlos-<variant>.img is shipped pre-built by the bp-fw artifact, not built here)
#
# Args:
#   $1 BASE24_IMG_BASENAME   $2 OUTPUT_ZIP   $3 NONHLOS_VARIANT(em|na)
#   $4 OVERLAY_STACK         $5 OVERLAY_PATH (container path, has overlays/+stacks/)
#   $6 OVERLAY_ENV (comma KEY=VAL)   $7 DEBUG(true|false)
#   $8 SIGNING_PROFILE(test|prod|none)   $9 SIGNING_KEY (key name under keys/)
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
SIGNING_PROFILE="${8:-test}"
SIGNING_KEY="${9:-}"
[ "$DEBUG" = "true" ] && set -x

section(){ echo; echo "==================== $* ===================="; }

# Reconcile + verify ext4 metadata. `mkfs.ext4 -d <dir>` can leave the SUPERBLOCK summary
# counts (s_free_blocks_count / s_free_inodes_count) stale: they disagree with the per-group
# descriptors, which are authoritative. A filesystem shipped that way reports far more free
# space than it has, so on the device the block allocator (or growfs/resize2fs) hands out
# blocks that already hold file data -> cross-linked blocks and inodes whose extents point
# past the (under-counted) end of the fs -> "end of extent exceeds allowed value" -> the
# initramfs fsck drops to BusyBox. e2fsck -fy rewrites the superblock summaries from the
# group descriptors. This caught a real corrupt build (free-count off by ~5 GiB). NEVER ship
# a rootfs that hasn't passed this gate. Exit codes: 0=clean, 1=errors corrected,
# 2=corrected+reboot-advised; >=4 = uncorrectable / operational error (fatal).
fsck_gate(){
  local img="$1" stage="$2" rc=0
  echo "INFO: e2fsck gate ($stage): $img"
  sudo e2fsck -fy "$img" || rc=$?
  if [ "$rc" -ge 4 ]; then
    echo "ERROR: e2fsck found uncorrectable errors in $img (stage=$stage, rc=$rc)" >&2
    exit 1
  fi
  [ "$rc" -eq 0 ] || echo "WARN: e2fsck corrected metadata in $img (stage=$stage, rc=$rc) — investigate the build step that produced it"
}

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
size=$(( used_kb*1024 + 6*1024*1024*1024 ))     # +6GB headroom for overlay (extra kernel, deps)
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
# Fix mkfs.ext4 -d's stale superblock summary counts before the overlay tool mounts the image.
fsck_gate "$ROOTFS" post-mkfs
echo "OK: $ROOTFS"

# ---- 2) efi.img (vendored GRUB) ---------------------------------------------
section "2) efi.img (vendored GRUB)"
( cd "$PROJ/scripts/efi" && ./make-efi-img.sh && mv -f efi.img "$OUT/efi.img" )
echo "OK: $OUT/efi.img"

# ---- 3) apply tachyon-overlays stack to rootfs.ext4 -------------------------
section "3) overlay stack: $OVERLAY_STACK"
RES_DIR="$work/overlay-resources"; mkdir -p "$RES_DIR"
# The add-qcm6490-bp-fw overlay reads $RESOURCES/QCM6490_fw.zip and unpacks the platform firmware
# (adsp/cdsp/qupv3fw + DSP libs) into /lib/firmware/qcom and /usr/lib/dsp. The composer must hand
# that zip to the overlay tool via -r; without it the firmware is silently missing from the rootfs.
[ -f "$IN/QCM6490_fw.zip" ] || { echo "ERROR: missing $IN/QCM6490_fw.zip (needed by add-qcm6490-bp-fw overlay)" >&2; exit 1; }
cp "$IN/QCM6490_fw.zip" "$RES_DIR/QCM6490_fw.zip"
ENV_OPT=(); [ -n "$OVERLAY_ENV" ] && ENV_OPT=(-e "$OVERLAY_ENV")
( cd "$OVERLAY_TOOL_DIR" && bash ./run-overlay.sh \
    -f "$ROOTFS" \
    -r "$RES_DIR" \
    -s "$OVERLAY_STACK" \
    -O "$OVERLAY_PATH" \
    -E "$OUT/efi.img" \
    -d "$DEBUG" \
    "${ENV_OPT[@]}" ) || { echo "ERROR: overlay apply failed" >&2; exit 1; }
# Final gate: the overlay tool dd-roundtrips and re-mounts the fs; verify the SHIPPED image is
# metadata-consistent (superblock counts == group descriptors) before it gets assembled/flashed.
fsck_gate "$ROOTFS" post-overlay
echo "OK: overlay applied to $ROOTFS"

# ---- 4) dtb.img + nonhlos-<variant>.img -------------------------------------
section "4) dtb.img (qcm6490-tachyon.dtb)"
"$PROJ/scripts/dtb/build-dtb.sh" "$IN/kernel" "$OUT/dtb.img"
section "4) nonhlos.img (variant=$NONHLOS_VARIANT, from bp-fw artifact)"
# The region-specific NON-HLOS image is built and shipped by the bp-fw release
# (nonhlos-em.img / nonhlos-na.img at the artifact top level); we just select one.
# No firmware blobs or build tooling live in this repo.
NONHLOS_SRC="$IN/nonhlos-$NONHLOS_VARIANT.img"
[ -f "$NONHLOS_SRC" ] || { echo "ERROR: missing $NONHLOS_SRC (the bp-fw artifact must ship nonhlos-$NONHLOS_VARIANT.img; run fetch_bp_fw)" >&2; exit 1; }
cp "$NONHLOS_SRC" "$OUT/nonhlos.img"
echo "OK: $OUT/nonhlos.img (from bp-fw artifact)"

# ---- 5) SIGN the bp-fw boot/firmware blobs (composer-owned, selectable key) --
section "5) sign bootbinaries (profile=$SIGNING_PROFILE, key=${SIGNING_KEY:-<none>})"
BOOTBIN_ZIP="$IN/QCM6490_bootbinaries.zip"
[ -f "$BOOTBIN_ZIP" ] || { echo "ERROR: missing $BOOTBIN_ZIP (run fetch_bp_fw)" >&2; exit 1; }
BB_UNSIGNED="$work/bootbin/unsigned"
BB_SIGNED="$work/bootbin/signed"
mkdir -p "$BB_UNSIGNED" "$BB_SIGNED"
unzip -q "$BOOTBIN_ZIP" -d "$BB_UNSIGNED"
# the zip carries a top-level QCM6490_bootbinaries/ dir; fall back to the unzip root
BB_SRC="$BB_UNSIGNED"; [ -d "$BB_UNSIGNED/QCM6490_bootbinaries" ] && BB_SRC="$BB_UNSIGNED/QCM6490_bootbinaries"
# multi_image.mbn vouches for ADSP/CDSP/WPSS which live in QCM6490_fw, not the bootbinaries;
# extract the fw tree so sign.sh can regenerate multi_image over the re-signed set.
FW_ZIP="$IN/QCM6490_fw.zip"; FW_DIR_ARG=""
if [ -f "$FW_ZIP" ]; then
  FW_UNZIP="$work/fw"; mkdir -p "$FW_UNZIP"; unzip -q "$FW_ZIP" -d "$FW_UNZIP"
  FW_ROOT="$FW_UNZIP"; [ -d "$FW_UNZIP/QCM6490_fw" ] && FW_ROOT="$FW_UNZIP/QCM6490_fw"
  FW_DIR_ARG="--fw-dir $FW_ROOT"
fi
bash "$PROJ/scripts/signing/sign.sh" \
  --in "$BB_SRC" \
  --out "$BB_SIGNED/QCM6490_bootbinaries" \
  --profile "$SIGNING_PROFILE" \
  --key "$SIGNING_KEY" \
  --keys-dir "$PROJ/keys" \
  $FW_DIR_ARG
SIGNED_BOOTBIN_ZIP="$work/QCM6490_bootbinaries.signed.zip"
( cd "$BB_SIGNED" && zip -rq "$SIGNED_BOOTBIN_ZIP" QCM6490_bootbinaries )
echo "OK: signed bootbinaries -> $SIGNED_BOOTBIN_ZIP"

# ---- 6) assemble (ptool + partition_ext) ------------------------------------
section "6) assemble factory image (ptool)"
"$PROJ/scripts/assemble/make_factory_img.sh" \
  --bootbinaries "$SIGNED_BOOTBIN_ZIP" \
  --system       "$ROOTFS" \
  --dtb_a        "$OUT/dtb.img" \
  --efi          "$OUT/efi.img" \
  --core_nhlos_a "$OUT/nonhlos.img" \
  --output       "$OUT/factory"

# ---- 6b) manifest.json (required by `particle flash --tachyon`) -------------
# particle flash reads manifest.json to locate the firehose + program/patch XMLs.
# The new-BP assembly does not inherit one, so synthesize it over the factory tree.
section "6b) manifest.json"
python3 - "$OUT/factory" "$OUTPUT_ZIP" "$OVERLAY_ENV" <<'PY'
import json, os, re, sys
factory, output_zip, env = sys.argv[1], sys.argv[2], (sys.argv[3] if len(sys.argv) > 3 else "")

m = re.match(r'tachyon-ubuntu-24\.04-([^-]+)-([^-]+)-([^-]+)-(.+)\.zip$', output_zip)
if not m:
    sys.exit("ERROR: cannot parse region/variant/board/version from %s" % output_zip)
region, variant, board, version = m.group(1), m.group(2), m.group(3), m.group(4)

envd = {}
for kv in env.split(','):
    if '=' in kv:
        k, v = kv.split('=', 1); envd[k.strip()] = v.strip()

src_map = [
    ('ubuntu-24.04', 'PKG_SRC_UBUNTU_24_04'),
    ('linux-particle', 'PKG_linux_particle'),
    ('particle-linux', 'PKG_particle_linux'),
    ('particle-tachyon-desktop-setup', 'PKG_particle_tachyon_desktop_setup'),
    ('particle-tachyon-ril', 'PKG_particle_tachyon_ril'),
    ('particle-tachyon-syscon', 'PKG_particle_tachyon_syscon'),
]
sources = [{'key': k, 'value': envd[e]} for k, e in src_map if envd.get(e)]

def sorted_xml(prefix):
    items = [f for f in os.listdir(factory) if re.fullmatch(prefix + r'\d+\.xml', f)]
    return sorted(items, key=lambda f: int(re.search(r'(\d+)', f).group(1)))

program_xml = sorted_xml('rawprogram')
patch_xml = sorted_xml('patch')
firehose = 'prog_firehose_ddr.elf'
if not os.path.exists(os.path.join(factory, firehose)):
    sys.exit("ERROR: missing %s in factory" % firehose)
if not program_xml:
    sys.exit("ERROR: no rawprogramN.xml in factory")

manifest = {
    '$schema': 'https://linux-dist.particle.io/schema/image_manifest_v1.json',
    'release_name': output_zip[:-4] if output_zip.endswith('.zip') else output_zip,
    'version': version, 'region': region, 'variant': variant,
    'platform': 'qcm6490', 'board': board, 'os': 'linux',
    'distribution': 'ubuntu', 'distribution_version': '24.04', 'distribution_variant': 'ubuntu',
    'sources': sources,
    'targets': [{'qcm6490': {'edl': {
        'base': '.', 'firehose': firehose,
        'program_xml': program_xml, 'patch_xml': patch_xml}}}],
}
with open(os.path.join(factory, 'manifest.json'), 'w') as f:
    json.dump(manifest, f, indent=2)
print("OK manifest.json: firehose=%s program_xml=%s patch_xml=%s" % (firehose, program_xml, patch_xml))
PY

# ---- 7) package -------------------------------------------------------------
section "7) package -> $OUTPUT_ZIP"
rm -f "$OUT/$OUTPUT_ZIP"
( cd "$OUT/factory" && zip -rq "$OUT/$OUTPUT_ZIP" . )
echo "DONE: $OUT/$OUTPUT_ZIP"
ls -lh "$OUT/$OUTPUT_ZIP"
