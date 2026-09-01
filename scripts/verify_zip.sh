#!/usr/bin/env bash
# verify_zip.sh — sanity-check a composed Tachyon system image zip without hardware.
#
# Usage: scripts/verify_zip.sh <image.zip> <series> <region> <variant>
#   e.g. scripts/verify_zip.sh .tmp/26.04/output/tachyon-ubuntu-26.04-RoW-headless-formfactor_dvt-9.9.999.zip 26.04 RoW headless
#
# Checks (zip-level; mounting rootfs.ext4 for content checks needs `make docker/shell`):
#   - manifest.json present, fields match series/region/variant, firehose + XML lists set
#   - sources[] carries the ubuntu-<series> base build id
#   - every filename referenced by rawprogram*.xml exists in the zip
#   - every referenced file fits its declared partition span
set -euo pipefail

ZIP="${1:?usage: verify_zip.sh <image.zip> <series> <region> <variant>}"
SERIES="${2:?series (24.04|26.04)}"
REGION="${3:?region (NA|RoW)}"
VARIANT="${4:?variant (headless|desktop)}"

test -s "$ZIP" || { echo "ERROR: $ZIP missing/empty" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

unzip -q "$ZIP" -d "$WORK"

python3 - "$WORK" "$SERIES" "$REGION" "$VARIANT" <<'PY'
import json, os, re, sys
import xml.etree.ElementTree as ET

root, series, region, variant = sys.argv[1:5]
fail = []

def check(cond, msg):
    (print("OK  " + msg) if cond else fail.append(msg))
    if not cond: print("FAIL " + msg)

mpath = os.path.join(root, 'manifest.json')
check(os.path.isfile(mpath), 'manifest.json present')
m = json.load(open(mpath))

check(m.get('distribution') == 'ubuntu', 'distribution == ubuntu')
check(m.get('distribution_version') == series, f'distribution_version == {series} (got {m.get("distribution_version")})')
check(m.get('region') == region, f'region == {region} (got {m.get("region")})')
check(m.get('variant') == variant, f'variant == {variant} (got {m.get("variant")})')
check(m.get('platform') == 'qcm6490', 'platform == qcm6490')

srcs = {s['key']: s['value'] for s in m.get('sources', [])}
base_key = 'ubuntu-' + series
check(base_key in srcs and srcs[base_key], f'sources[] has {base_key} (base build id: {srcs.get(base_key)})')

edl = m['targets'][0]['qcm6490']['edl']
check(bool(edl.get('program_xml')), 'program_xml list non-empty')
check(bool(edl.get('patch_xml')), 'patch_xml list non-empty')
firehose = edl.get('firehose', '')
check(os.path.isfile(os.path.join(root, firehose)), f'firehose present ({firehose})')

# rawprogram*.xml: every referenced file exists and fits its partition span.
missing, oversize, nfiles = [], [], 0
for xmlname in edl['program_xml']:
    tree = ET.parse(os.path.join(root, xmlname))
    for p in tree.getroot().iter('program'):
        fn = (p.get('filename') or '').strip()
        if not fn:
            continue
        nfiles += 1
        fp = os.path.join(root, fn)
        if not os.path.isfile(fp):
            missing.append(f'{fn} (from {xmlname})')
            continue
        try:
            sectors = int(p.get('num_partition_sectors'))
            ssize = int(p.get('SECTOR_SIZE_IN_BYTES'))
        except (TypeError, ValueError):
            continue
        span = sectors * ssize
        # sparse=true images are written expanded; compare against the span anyway
        if os.path.getsize(fp) > span:
            oversize.append(f'{fn}: {os.path.getsize(fp)} > {span} ({xmlname})')
check(not missing, 'all rawprogram-referenced files present' + ('' if not missing else ': MISSING ' + ', '.join(missing)))
check(not oversize, 'all files fit their partition spans' + ('' if not oversize else ': ' + '; '.join(oversize)))
print(f'.. {nfiles} partition file references checked')

if fail:
    print(f'\n{len(fail)} check(s) FAILED', file=sys.stderr)
    sys.exit(1)
print('\nAll zip-level checks passed.')
PY
