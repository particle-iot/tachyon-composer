#!/usr/bin/env python3
"""Collect stock QLI runtime RPMs and their pinned build provenance."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024*1024), b''):
            value.update(chunk)
    return value.hexdigest()


def collect(config_path, workspace, bundle):
    config = json.loads(config_path.read_text())
    if not (workspace / '.particle-runtime-workspace').is_file() or (workspace / '.particle-sdk-workspace').exists():
        raise ValueError('Not a stock runtime build workspace')
    sources = {}
    for path in sorted(workspace.iterdir()):
        if (path / '.git').exists():
            sources[path.name] = subprocess.check_output(['git', '-C', str(path), 'rev-parse', 'HEAD'], text=True).strip()
    if sources.get('meta-qcom-releases') != config['yocto']['revision']:
        raise ValueError('Runtime sources do not match QLI release lock')
    graph = json.loads((workspace / 'build/runtime-graph.json').read_text())
    if not graph.get('recipe_count') or not graph.get('task_count'):
        raise ValueError('Runtime graph audit missing')
    paths = sorted((workspace / 'build/tmp/deploy/rpm').rglob('*.rpm'))
    if not paths:
        raise ValueError('No runtime RPM outputs')
    rows = []
    names = set()
    for path in paths:
        if path.is_symlink() or path.name in names:
            raise ValueError('Duplicate or symlinked runtime RPM: ' + path.name)
        names.add(path.name)
        fields = subprocess.check_output(['rpm', '-qp', '--qf', '%{NAME}\n%{VERSION}\n%{RELEASE}\n%{ARCH}\n%{SOURCERPM}', str(path)], text=True).splitlines()
        if fields[3] not in ('armv8_2a', 'aarch64', 'noarch', 'rb3gen2_core_kit'):
            raise ValueError('Unexpected runtime RPM architecture: ' + fields[3])
        if fields[0].endswith(('-dbg', '-dev', '-staticdev', '-ptest', '-doc')) or '-locale-' in fields[0] or fields[0] == 'libgpiod-gpiosim':
            continue
        rows.append(dict(zip(('name', 'version', 'release', 'architecture', 'source_rpm'), fields),
                         filename=path.name, sha256=digest(path), source_revision=config['yocto']['revision'],
                         qli_release_revision=config['yocto']['revision']))
    required = {'jq', 'libonig5', 'socat', 'sudo', 'grep', 'sed', 'networkmanager-daemon', 'networkmanager-wwan', 'networkmanager-wifi', 'tzdata', 'tzdata-core'}
    if required - {row['name'] for row in rows}:
        raise ValueError('Missing requested runtime package outputs')
    bundle.mkdir(parents=True, exist_ok=True)
    with tarfile.open(bundle / 'runtime-rpms.tar.gz', 'w:gz') as archive:
        selected = {row['filename'] for row in rows}
        for path in paths:
            if path.name not in selected:
                continue
            archive.add(path, arcname=path.name, recursive=False)
    (bundle / 'packages.json').write_text(json.dumps(rows, indent=2) + '\n')
    (bundle / 'source-revisions.json').write_text(json.dumps(sources, indent=2) + '\n')
    shutil.copy2(config_path, bundle / 'build-versions.json')
    shutil.copy2(workspace / 'build/runtime-graph.json', bundle / 'runtime-graph.json')
    files = ('runtime-rpms.tar.gz', 'packages.json', 'build-versions.json', 'kas-config.yml', 'runtime-graph.json', 'source-revisions.json')
    (bundle / 'SHA256SUMS').write_text(''.join(f'{digest(bundle / name)}  {name}\n' for name in files))
    print(f'Recorded {len(rows)} stock QLI runtime RPMs')


if __name__ == '__main__':
    collect(*(Path(arg).resolve() for arg in sys.argv[1:]))
