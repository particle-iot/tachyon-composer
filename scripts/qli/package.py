#!/usr/bin/env python3
"""Package QLI using the same complete Tachyon flash layout as Ubuntu 24.04."""
import json
from datetime import datetime, timezone
from pathlib import Path
import shutil
import sys
import xml.etree.ElementTree as ET
from assets import digest
from layout import (SECTOR, PROGRAM_XML, PATCH_XML, NV, check_protected,
                    sector_number, validate_layout)

# OS and firmware payloads from the shared Ubuntu 24.04 assembler.
# GPT installation is validated separately; NV/persist writes are forbidden.
ALLOWED = {
    0: {'system', 'efi', 'misc'},
    1: {'xbl_a', 'xbl_config_a'},
    2: {'xbl_a', 'xbl_config_a'},
    3: {'cdt'},
    6: {'aop_a', 'dtb_a', 'xbl_ramdump_a', 'uefi_a', 'tz_a', 'hyp_a',
        'devcfg_a', 'qupfw_a', 'uefisecapp_a', 'imagefv_a', 'shrm_a',
        'core_nhlos_a', 'multiimgoem_a', 'cpucp_a', 'toolsfv'},
}
REQUIRED = {(0, 'system'), (0, 'efi'), (0, 'misc'), (6, 'dtb_a'), (6, 'core_nhlos_a')}


def programs(factory, *, read_bytes=None, payload_size=None, payload_digest=None):
    read_bytes = read_bytes or (lambda name: (factory / name).read_bytes())
    payload_size = payload_size or (lambda name: (factory / name).stat().st_size)
    payload_digest = payload_digest or (lambda name: digest(factory / name))
    validate_layout(read_bytes)
    rows = []
    for name in PROGRAM_XML:
        for p in ET.fromstring(read_bytes(name)):
            a = dict(p.attrib)
            filename, label = a.get('filename', ''), a['label']
            if not filename:
                continue  # A declaration is retained, but does not write data.
            lun = int(a['physical_partition_number'])
            is_gpt = label in {'PrimaryGPT', 'BackupGPT'}
            if not is_gpt and label not in ALLOWED.get(lun, set()):
                raise ValueError(f'Forbidden write: LUN {lun} {label}')
            if Path(filename).name != filename:
                raise ValueError('Payload must be a plain filename')
            count = int(a['num_partition_sectors'])
            size = payload_size(filename)
            if size <= 0 or (count and size > count * SECTOR):
                raise ValueError(f'Missing/oversize payload: {filename}')
            if label == 'misc' and size != count * SECTOR:
                raise ValueError('misc payload must cover the declared setup partition')
            # Retain the assembler's partition capacity in XML, like Ubuntu.
            # The sidecar records the actual payload extent for bounds checks.
            written = (size + SECTOR - 1) // SECTOR
            row = {'lun': lun, 'label': label, 'size_bytes': written * SECTOR,
                   'filename': filename, 'sha256': payload_digest(filename)}
            if label == 'BackupGPT':
                row['start_sector'] = a['start_sector']
            else:
                start = int(a['start_sector'])
                row['start_bytes'] = start * SECTOR
                check_protected(lun, start, written)
            rows.append((a, row))
    keys = [(r['lun'], r['label']) for _, r in rows]
    if len(keys) != len(set(keys)) or not REQUIRED.issubset(keys):
        raise ValueError('Missing required partition or duplicate write')
    # All boot/firmware payloads used by Ubuntu 24.04 must be present.
    if not {(lun, label) for lun, labels in ALLOWED.items() for label in labels}.issubset(keys):
        raise ValueError('Incomplete Ubuntu-compatible payload set')
    for lun in range(7):
        extents = sorted((r['start_bytes'], r['start_bytes'] + r['size_bytes'])
                         for _, r in rows if r['lun'] == lun and 'start_bytes' in r)
        if any(a[1] > b[0] for a, b in zip(extents, extents[1:])):
            raise ValueError(f'Overlapping writes on LUN {lun}')
    return rows


def compare_layout(writes, baseline):
    """Check physical LUN capacities, not the previous OS's partition names."""
    disks = {d['lun']: d for d in baseline.get('disks', [])}
    if set(disks) != set(range(7)):
        raise ValueError('Baseline must record capacities of all seven physical LUNs')
    by_key = {(p['lun'], p['label']): p for p in baseline['partitions']}
    if len(by_key) != len(baseline['partitions']):
        raise ValueError('Ambiguous baseline partition labels')
    for label, (start, count) in NV.items():
        p = by_key.get((5, label), {})
        if (p.get('start_bytes'), p.get('size_bytes')) != (start * SECTOR, count * SECTOR):
            raise ValueError(f'Board fixed provisioning geometry mismatch: {label}')
    resolved = {}
    for w in writes:
        disk = disks[w['lun']]
        if disk['sector_size'] != SECTOR or disk['size_bytes'] % SECTOR:
            raise ValueError('Board logical sector size differs from the image')
        start = w.get('start_bytes')
        if start is None:
            start = sector_number(w['start_sector'], disk['size_bytes'] // SECTOR) * SECTOR
        end = start + w['size_bytes']
        if start < 0 or end > disk['size_bytes']:
            raise ValueError(f'Write exceeds physical LUN {w["lun"]}: {w["label"]}')
        if w['label'] not in {'PrimaryGPT', 'BackupGPT'} and end > disk['size_bytes'] - 5 * SECTOR:
            raise ValueError('Payload overlaps backup GPT')
        check_protected(w['lun'], start // SECTOR, w['size_bytes'] // SECTOR)
        resolved.setdefault(w['lun'], []).append((start, end))
    for lun, extents in resolved.items():
        extents.sort()
        if any(a[1] > b[0] for a, b in zip(extents, extents[1:])):
            raise ValueError(f'Overlapping writes on physical LUN {lun}')


def package(factory, config, region, version, name):
    rows = programs(factory)
    # Keep exactly the normal Ubuntu-style flash operations, including empty
    # declarations (misc/persist/NV), primary/backup GPTs and disk-size patches.
    # The assembler's wipe and UFS provisioning files are never distributed.
    keep = {r['filename'] for _, r in rows} | set(PROGRAM_XML + PATCH_XML) | {
        'prog_firehose_ddr.elf', 'initramfs-files.txt', 'package-validation.json'}
    if not (factory / 'prog_firehose_ddr.elf').is_file():
        raise ValueError('Missing Particle firehose')
    for p in factory.iterdir():
        if p.name not in keep:
            shutil.rmtree(p) if p.is_dir() else p.unlink()
    manifest = {
        '$schema': 'https://linux-dist.particle.io/schema/image_manifest_v1.json',
        'release_name': name, 'version': version, 'region': region,
        'build_date': datetime.now(timezone.utc).isoformat(),
        'variant': 'headless', 'platform': 'qcm6490', 'board': 'formfactor_dvt', 'os': 'linux',
        **{k: config[k] for k in ('distribution', 'distribution_version', 'distribution_variant')},
        'sources': [{'key': 'linux-particle', 'value': config['kernel_package_version']},
                    {'key': 'bp-fw', 'value': config['bp_fw_version']},
                    {'key': 'qli-rootfs-sha256', 'value': config['assets']['rootfs']['sha256']}],
        'targets': [{'qcm6490': {'edl': {'base': '.', 'firehose': 'prog_firehose_ddr.elf',
                                       'program_xml': PROGRAM_XML, 'patch_xml': PATCH_XML}}}],
    }
    for filename, obj in [('manifest.json', manifest), ('sources.json', config),
                          ('flash-layout.json', {'partitions': [r for _, r in rows]})]:
        (factory / filename).write_text(json.dumps(obj, indent=2) + '\n')
    entries = sorted(p for p in factory.iterdir() if p.is_file())
    (factory / 'SHA256SUMS').write_text(''.join(f'{digest(p)}  {p.name}\n' for p in entries))
    print(f'Validated {len(rows)} writes including 14 GPTs and 7 patch files; protected data untouched')


if __name__ == '__main__':
    package(Path(sys.argv[1]), json.loads(Path(sys.argv[2]).read_text()), *sys.argv[3:6])
    import jsonschema
    schemas = Path(__file__).parent / 'schemas'
    schema = json.loads((schemas / 'image_manifest_v1.json').read_text())
    schema['allOf'][0] = json.loads((schemas / 'build_metadata_v1.json').read_text())
    jsonschema.validate(json.loads((Path(sys.argv[1]) / 'manifest.json').read_text()), schema)
    print('Particle image manifest schema validation passed')
