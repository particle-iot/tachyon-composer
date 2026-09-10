#!/usr/bin/env python3
"""Make a GPT-preserving QLI experiment ZIP tree from Particle's assembly."""
import json
import re
from datetime import datetime, timezone
from pathlib import Path
import shutil
import sys
import xml.etree.ElementTree as ET
from assets import digest

# Only payload partitions from the pinned Tachyon layout. No NV, persist, GPT,
# erase commands, provisioning, or reference-board geometry is accepted.
ALLOWED = {
    0: {'system', 'efi'},
    1: {'xbl_a', 'xbl_config_a'},
    2: {'xbl_a', 'xbl_config_a'},
    3: {'cdt'},
    6: {'aop_a', 'dtb_a', 'xbl_ramdump_a', 'uefi_a', 'tz_a', 'hyp_a',
        'devcfg_a', 'qupfw_a', 'uefisecapp_a', 'imagefv_a', 'shrm_a',
        'core_nhlos_a', 'multiimgoem_a', 'cpucp_a', 'toolsfv'},
}
REQUIRED = {(0, 'system'), (0, 'efi'), (6, 'dtb_a'), (6, 'core_nhlos_a')}


def programs(factory):
    rows = []
    for path in sorted(factory.glob('rawprogram[0-9]*.xml')):
        if not re.fullmatch(r'rawprogram\d+\.xml', path.name):
            continue
        for p in ET.parse(path).getroot():
            if p.tag != 'program':
                raise ValueError(f'Unexpected {p.tag} in {path}')
            a = dict(p.attrib)
            filename, label = a.get('filename', ''), a.get('label', '')
            if not filename or label in {'PrimaryGPT', 'BackupGPT'}:
                continue
            lun = int(a['physical_partition_number'])
            if label not in ALLOWED.get(lun, set()):
                raise ValueError(f'Forbidden write: LUN {lun} {label}')
            if Path(filename).name != filename:
                raise ValueError('Payload must be a plain filename')
            sector = int(a['SECTOR_SIZE_IN_BYTES'])
            start, count = int(a['start_sector']), int(a['num_partition_sectors'])
            if sector != 4096 or start < 0 or count < 0 or (count == 0 and (lun, label) != (0, 'system')):
                raise ValueError(f'Invalid extent: {a}')
            payload = factory / filename
            if not payload.is_file() or not payload.stat().st_size or (count and payload.stat().st_size > count * sector):
                raise ValueError(f'Missing/oversize payload: {filename}')
            if int(a.get('file_sector_offset', '0')) != 0:
                raise ValueError('Partial payload offsets are not supported')
            # ptool emits count=0 for the growing system partition. The experiment
            # writes only the supplied image, with an explicit finite extent.
            count = (payload.stat().st_size + sector - 1) // sector
            a['num_partition_sectors'] = str(count)
            a['size_in_KB'] = str(count * sector // 1024)
            if a.get('sparse', 'false').lower() != 'false':
                raise ValueError('Expected raw payloads; sparse extents need separate validation')
            rows.append((a, {'lun': lun, 'label': label, 'start_bytes': start * sector,
                             'size_bytes': count * sector, 'filename': filename,
                             'sha256': digest(payload)}))
    keys = [(r['lun'], r['label']) for _, r in rows]
    if len(keys) != len(set(keys)) or not REQUIRED.issubset(keys):
        raise ValueError('Missing required partition or duplicate write')
    for lun in ALLOWED:
        extents = sorted((r['start_bytes'], r['start_bytes'] + r['size_bytes'])
                         for _, r in rows if r['lun'] == lun)
        if any(a[1] > b[0] for a, b in zip(extents, extents[1:])):
            raise ValueError(f'Overlapping writes on LUN {lun}')
    return rows


def compare_layout(writes, baseline):
    """Baseline partitions are byte extents, indexed by UFS LUN + GPT label."""
    by_key = {(p['lun'], p['label']): p for p in baseline['partitions']}
    if len(by_key) != len(baseline['partitions']):
        raise ValueError('Ambiguous baseline partition labels')
    for w in writes:
        p = by_key.get((w['lun'], w['label']))
        if p is None or p['start_bytes'] != w['start_bytes'] or p['size_bytes'] < w['size_bytes']:
            raise ValueError(f'Board layout mismatch: LUN {w["lun"]} {w["label"]}')
        if p.get('sector_size', 4096) != 4096:
            raise ValueError('Board logical sector size differs from the image')


def package(factory, config, region, version, name):
    rows = programs(factory)
    xml = ET.Element('data')
    for attrs, _ in rows:
        ET.SubElement(xml, 'program', attrs)
    # Delete all unused assembler output, so even a flasher which scans *.xml
    # cannot accidentally pick up a GPT or provisioning operation.
    keep = {r['filename'] for _, r in rows} | {'prog_firehose_ddr.elf', 'initramfs-files.txt'}
    if not (factory / 'prog_firehose_ddr.elf').is_file():
        raise ValueError('Missing Particle firehose')
    for p in factory.iterdir():
        if p.name not in keep:
            shutil.rmtree(p) if p.is_dir() else p.unlink()
    ET.indent(xml)
    ET.ElementTree(xml).write(factory / 'rawprogram_qli.xml', encoding='utf-8', xml_declaration=True)
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
                                       'program_xml': ['rawprogram_qli.xml'], 'patch_xml': []}}}],
    }
    for filename, obj in [('manifest.json', manifest), ('sources.json', config),
                          ('flash-layout.json', {'partitions': [r for _, r in rows]})]:
        (factory / filename).write_text(json.dumps(obj, indent=2) + '\n')
    entries = sorted(p for p in factory.iterdir() if p.is_file())
    (factory / 'SHA256SUMS').write_text(''.join(f'{digest(p)}  {p.name}\n' for p in entries))
    print(f'Validated {len(rows)} in-place writes; no GPT, NV, persist or UFS provisioning')


if __name__ == '__main__':
    package(Path(sys.argv[1]), json.loads(Path(sys.argv[2]).read_text()), *sys.argv[3:6])
    import jsonschema
    schemas = Path(__file__).parent / 'schemas'
    schema = json.loads((schemas / 'image_manifest_v1.json').read_text())
    schema['allOf'][0] = json.loads((schemas / 'build_metadata_v1.json').read_text())
    jsonschema.validate(json.loads((Path(sys.argv[1]) / 'manifest.json').read_text()), schema)
    print('Particle image manifest schema validation passed')
