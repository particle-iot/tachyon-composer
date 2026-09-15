#!/usr/bin/env python3
"""Wrap the pinned Kigen serial LPA in an RPM, without rebuilding vendor code."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from assets import digest
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('versions')
parser.add_argument('output')
parser.add_argument('--binary', type=Path, help='Previously downloaded pinned LPA binary')
args = parser.parse_args()
config = json.loads(Path(args.versions).read_text())
lpa = config['lpa']
out = Path(args.output).resolve()
out.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory() as temporary:
    work = Path(temporary)
    for name in ('SOURCES', 'SPECS', 'BUILD', 'BUILDROOT', 'RPMS', 'SRPMS'):
        (work / name).mkdir()
    if args.binary:
        shutil.copyfile(args.binary, work / 'SOURCES' / lpa['filename'])
    else:
        subprocess.run(['gh', 'release', 'download', lpa['version'], '--repo', lpa['repository'],
                        '--pattern', lpa['filename'], '--dir', str(work / 'SOURCES')], check=True)
    if digest(work / 'SOURCES' / lpa['filename']) != lpa['sha256']:
        raise SystemExit('Kigen LPA checksum mismatch')
    spec = work / 'SPECS/lpa.spec'
    spec.write_text(f'''Name: particle-kigen-lpa
Version: {lpa['version']}
Release: 1
Summary: Kigen serial eSIM local profile assistant for Tachyon
License: Proprietary
Source0: {lpa['filename']}
%global debug_package %{{nil}}
%global __os_install_post %{{nil}}
%description
Pinned Kigen LPA using the modem serial AT transport selected by Particle RIL.
%install
install -D -m 755 %{{SOURCE0}} %{{buildroot}}/usr/bin/lpa
%files
/usr/bin/lpa
''')
    subprocess.run(['rpmbuild', '-bb', '--target', 'aarch64', '--define', f'_topdir {work}',
                    '--define', '_buildhost qli-build',
                    '--define', 'use_source_date_epoch_as_buildtime 1',
                    '--define', 'clamp_mtime_to_source_date_epoch 1', str(spec)],
                   env=dict(os.environ, SOURCE_DATE_EPOCH=str(lpa['source_date_epoch'])), check=True)
    records = []
    for package in (work / 'RPMS/aarch64').glob('*.rpm'):
        destination = out / package.name
        destination.write_bytes(package.read_bytes())
        records.append(dict(name='particle-kigen-lpa', version=lpa['version'], release='1',
            architecture='aarch64', filename=package.name, sha256=digest(package),
            source_revision=lpa['source_revision'], qli_release_revision=config['yocto']['revision']))
    if len(records) != 1:
        raise SystemExit('Expected exactly one Kigen RPM')
    (out / 'packages.json').write_text(json.dumps(records, indent=2) + '\n')
