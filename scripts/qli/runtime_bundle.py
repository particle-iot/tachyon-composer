"""Read selected, individually pinned RPMs from a pinned public runtime bundle."""
import json
from pathlib import Path
import re
import shutil
import tarfile
import tempfile

from assets import digest, fetch

PREFIX = 'candidates/qli-2.0/runtime/v1'
BASE_URL = 'https://packages.particle.io/'
IDENTITY = ('name', 'version', 'release', 'architecture', 'filename', 'sha256',
            'source_revision', 'qli_release_revision')


def stage_runtime(config, cache, packages):
    """Verify provenance and selected member hashes before populating the RPM cache.

    Never extract an archive path or install every RPM in the build closure. The
    image lock selects packages; DNF subsequently checks their dependencies.
    """
    if not packages:
        return
    pin = config['qli_runtime']
    key = pin['manifest_key']
    if not re.fullmatch(re.escape(PREFIX) + r'/[0-9a-f]{64}/manifest\.json', key):
        raise ValueError('Invalid pinned runtime manifest key')
    if not re.fullmatch(r'[0-9a-f]{64}', pin['sha256']):
        raise ValueError('Invalid runtime manifest checksum')
    cache = Path(cache)
    bundle = cache / 'runtime-bundle' / pin['sha256']
    bundle.mkdir(parents=True, exist_ok=True)
    fetch(bundle, dict(filename='manifest.json', url=BASE_URL + key, sha256=pin['sha256']))
    manifest = json.loads((bundle / 'manifest.json').read_text())
    if manifest['inputs']['yocto'] != config['yocto']:
        raise ValueError('Runtime bundle QLI source lock mismatch')
    for name in ('packages.json', 'runtime-rpms.tar.gz'):
        checksum = manifest['files'][name]
        fetch(bundle, dict(filename=name, sha256=checksum,
                           url=f'{BASE_URL}{PREFIX}/objects/{checksum}/{name}'))
    inventory = json.loads((bundle / 'packages.json').read_text())
    by_filename = {row['filename']: row for row in inventory}
    if len(by_filename) != len(inventory):
        raise ValueError('Duplicate RPM in runtime inventory')
    wanted = {}
    for package in packages:
        name = package['filename']
        if Path(name).name != name or not name.endswith('.rpm') or name in wanted:
            raise ValueError('Invalid or duplicate selected runtime RPM filename')
        row = by_filename.get(name, {})
        if any(row.get(field) != package[field] for field in IDENTITY):
            raise ValueError('Runtime RPM does not match image lock: ' + name)
        wanted[name] = package
    with tempfile.TemporaryDirectory(dir=bundle) as directory:
        staging = Path(directory)
        seen = set()
        with tarfile.open(bundle / 'runtime-rpms.tar.gz', 'r:gz') as archive:
            for member in archive:
                if Path(member.name).name != member.name or not member.isfile() or member.name in seen:
                    raise ValueError('Unsafe or duplicate member in runtime archive')
                seen.add(member.name)
                if member.name not in wanted:
                    continue
                target = staging / member.name
                with archive.extractfile(member) as source, target.open('wb') as output:
                    shutil.copyfileobj(source, output)
                if digest(target) != wanted[member.name]['sha256']:
                    raise ValueError('Runtime RPM checksum mismatch: ' + member.name)
        if wanted.keys() - seen:
            raise ValueError('Selected runtime RPM missing from archive')
        # Publish only after the entire selection passes verification.
        for name in wanted:
            target = cache / name
            if target.exists() and digest(target) != wanted[name]['sha256']:
                raise ValueError('Cached runtime RPM checksum mismatch: ' + name)
        for name in wanted:
            (staging / name).replace(cache / name)
