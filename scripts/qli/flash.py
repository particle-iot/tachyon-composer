#!/usr/bin/env python3
"""Verify a QLI bundle and baseline before Embroid inline flashing."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import zipfile

from assets import digest
from package import programs, compare_layout
from layout import PROGRAM_XML, PATCH_XML

BACKUPS = {'fsc', 'fsg', 'modemst1', 'modemst2', 'nvdata1', 'nvdata2', 'persist'}


def verify_bundle(path):
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        if len(names) != len(set(names)) or any(Path(n).name != n for n in names):
            raise ValueError('Duplicate or non-flat ZIP entries')
        sums = dict((name, sha) for sha, name in
                    (line.split(maxsplit=1) for line in z.read('SHA256SUMS').decode().splitlines()))
        if set(sums) != set(names) - {'SHA256SUMS'}:
            raise ValueError('Archive checksum coverage is incomplete')
        for name, expected in sums.items():
            h = hashlib.sha256()
            with z.open(name) as f:
                for chunk in iter(lambda: f.read(1024*1024), b''): h.update(chunk)
            if h.hexdigest() != expected:
                raise ValueError(f'Archive hash mismatch: {name}')
        m = json.loads(z.read('manifest.json'))
        if (m['distribution'], m['distribution_version'], m['distribution_variant']) != ('qualcomm-linux','2.0','open'):
            raise ValueError('Not a QLI 2.0 open image')
        edl = m['targets'][0]['qcm6490']['edl']
        if edl['program_xml'] != PROGRAM_XML or edl['patch_xml'] != PATCH_XML:
            raise ValueError('Unexpected flash operation files')
        if {n for n in names if n.endswith('.xml')} != set(PROGRAM_XML + PATCH_XML):
            raise ValueError('Archive contains extra operation XML')
        layout = json.loads(z.read('flash-layout.json'))['partitions']
        expected = [r for _, r in programs(None, read_bytes=z.read,
                    payload_size=lambda name: z.getinfo(name).file_size,
                    payload_digest=lambda name: sums[name])]
        if layout != expected:
            raise ValueError('Program and recorded layout differ')
        return m, layout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image', type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--check-only', action='store_true')
    mode.add_argument('--prepare-only', action='store_true',
                      help='Verify the full board/backup/recovery preflight without invoking Embroid')
    parser.add_argument('--baseline', type=Path)
    parser.add_argument('--backup-dir', type=Path)
    parser.add_argument('--recovery-image', type=Path)
    parser.add_argument('--resource', default='head2-tachyon')
    args = parser.parse_args()
    manifest, writes = verify_bundle(args.image)
    print(f'Verified QLI bundle: {args.image.name}', flush=True)
    if args.baseline:
        baseline = json.loads(args.baseline.read_text())
        if baseline.get('region') != manifest['region']:
            raise ValueError('Image region differs from recorded board region')
        compare_layout(writes, baseline)
    if args.check_only: return
    if not all((args.baseline, args.backup_dir, args.recovery_image)):
        parser.error('Flashing requires --baseline, --backup-dir and --recovery-image')
    backup = json.loads((args.backup_dir/'backup.json').read_text())
    if backup['board_serial'] != baseline['board_serial']:
        raise ValueError('Backup is for a different board')
    if {p['label'] for p in backup['files']} != BACKUPS:
        raise ValueError('Incomplete NV/persist backup')
    for p in backup['files']:
        if Path(p['path']).name != p['path'] or digest(args.backup_dir/p['path']) != p['sha256']:
            raise ValueError('Backup filename or digest mismatch')
    recovery_digest = Path(str(args.recovery_image)+'.sha256').read_text().split()[0]
    if digest(args.recovery_image) != recovery_digest:
        raise ValueError('Ubuntu recovery digest mismatch')
    with zipfile.ZipFile(args.recovery_image) as z:
        recovery = json.loads(z.read('manifest.json'))
        if (recovery['distribution'],recovery['distribution_version'],recovery['region']) != ('ubuntu','24.04',baseline['region']):
            raise ValueError('Recovery image must be Ubuntu 24.04 for this region')
    print('Board layout, NV/persist backups and Ubuntu recovery image verified', flush=True)
    if args.prepare_only: return
    # Embroid acquires programming mode and verifies programming. --boot only
    # requests NORMAL power-on after successful completion, never after failure.
    subprocess.run(['embroid','flash',args.resource,str(args.image.resolve()),
                    '--target','qcm6490','--timeout','1800','--boot'],check=True)


if __name__ == '__main__': main()
