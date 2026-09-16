#!/usr/bin/env python3
"""Run as root on Ubuntu Tachyon; capture byte geometry and optional NV backup."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

LABELS = {'fsc', 'fsg', 'modemst1', 'modemst2', 'nvdata1', 'nvdata2', 'persist'}


def run(*args):
    return subprocess.check_output(args, text=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--backup-dir', type=Path)
    args = parser.parse_args()
    compatible = Path('/proc/device-tree/compatible').read_bytes()
    if b'tachyon' not in compatible:
        raise SystemExit('Refusing to capture a board without Tachyon device-tree identity')
    disks = json.loads(run('lsblk', '-J', '-d', '-o', 'PATH,HCTL,TYPE'))['blockdevices']
    parts = []
    capacities = []
    for disk in disks:
        if disk['type'] != 'disk' or not disk.get('hctl'):
            continue
        lun = int(disk['hctl'].split(':')[-1])
        capacities.append({'lun': lun, 'size_bytes': int(run('blockdev', '--getsize64', disk['path'])),
                           'sector_size': int(run('blockdev', '--getss', disk['path']))})
        table = json.loads(run('sfdisk', '-J', disk['path']))['partitiontable']
        # Ubuntu 20.04's sfdisk JSON omits sectorsize; query the real device.
        sector = table.get('sectorsize', capacities[-1]['sector_size'])
        if table.get('unit') != 'sectors' or sector != capacities[-1]['sector_size']:
            raise RuntimeError('Unexpected sfdisk sector geometry')
        for p in table['partitions']:
            parts.append({'lun': lun, 'label': p.get('name', ''), 'path': p['node'],
                          'start_bytes': p['start'] * sector, 'size_bytes': p['size'] * sector,
                          'sector_size': sector, 'uuid': p.get('uuid')})
    version_file = Path('/etc/particle/distro_versions.json')
    versions = json.loads(version_file.read_text()) if version_file.exists() else {}
    distro = versions.get('distro', {})
    baseline = {'board_serial': Path('/sys/devices/soc0/serial_number').read_text().strip(),
                'hostname': run('hostname').strip(), 'kernel': run('uname', '-r').strip(),
                'region': distro.get('region'), 'distro_versions': versions, 'partitions': parts, 'disks': capacities}
    if not args.backup_dir:
        print(json.dumps(baseline, indent=2)); return
    directory = args.backup_dir
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    (directory/'baseline.json').write_text(json.dumps(baseline, indent=2)+'\n')
    # Ubuntu's netplan renderer stores active Wi-Fi keyfiles under /run rather
    # than /etc. Save both those profiles and their source configuration.
    for source, name in (
            ('/etc/NetworkManager/system-connections', 'network-profiles'),
            ('/run/NetworkManager/system-connections', 'network-profiles-runtime'),
            ('/etc/netplan', 'netplan'),
            ('/etc/systemd/network', 'systemd-network'),
            ('/etc/wpa_supplicant', 'wpa-supplicant')):
        profiles = Path(source)
        if profiles.is_dir():
            shutil.copytree(profiles, directory/name)
    selected = [p for p in parts if p['label'] in LABELS]
    if {p['label'] for p in selected} != LABELS or len(selected) != len(LABELS):
        raise SystemExit('Missing or ambiguous NV/persist partitions')
    active = []
    for unit in ('ModemManager', 'ofono', 'particle-tachyon-rild', 'rmtfs'):
        if subprocess.run(['systemctl', 'is-active', '--quiet', unit]).returncode == 0:
            active.append(unit)
    frozen = False
    records = []
    try:
        if active: subprocess.run(['systemctl', 'stop', *active], check=True)
        if subprocess.run(['mountpoint', '-q', '/persist']).returncode == 0:
            subprocess.run(['fsfreeze', '-f', '/persist'], check=True); frozen = True
        for p in selected:
            dst = directory/(p['label']+'.img')
            with open(p['path'], 'rb', buffering=0) as src, dst.open('wb') as out:
                shutil.copyfileobj(src, out, 1024*1024)
            if dst.stat().st_size != p['size_bytes']:
                raise RuntimeError(f'Incomplete backup: {dst.name}')
            h=hashlib.sha256()
            with dst.open('rb') as f:
                for b in iter(lambda:f.read(1024*1024), b''):h.update(b)
            records.append({'label': p['label'], 'path': dst.name, 'sha256': h.hexdigest()})
    finally:
        if frozen: subprocess.run(['fsfreeze', '-u', '/persist'], check=True)
        if active: subprocess.run(['systemctl', 'start', *active], check=True)
    (directory/'backup.json').write_text(json.dumps({'board_serial': baseline['board_serial'],
                                                    'files': records},indent=2)+'\n')
    print(f'Baseline and {len(records)} verified partition backups in {directory}')


if __name__ == '__main__': main()
