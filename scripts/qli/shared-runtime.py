#!/usr/bin/env python3
"""Share checksum-verified QLI runtime bundles through the existing package S3 bucket."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

FILES = ('runtime-rpms.tar.gz', 'packages.json', 'build-versions.json', 'kas-config.yml', 'runtime-graph.json', 'source-revisions.json')
PREFIX = 'candidates/qli-2.0/runtime/v1'
KAS_VERSION = '4.8.2'


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def encoded(value):
    return (json.dumps(value, sort_keys=True, indent=2) + '\n').encode()


def inputs(composer):
    # Image/package/overlay changes do not invalidate the runtime RPM. Changes to its
    # source lock, build configuration or checkout implementation do.
    return dict(schema=1, host='x86_64-linux', kas=KAS_VERSION,
                yocto=json.loads((composer / 'versions.json').read_text())['yocto'],
                scripts={name: digest(composer / 'scripts/qli' / name)
                         for name in ('build-runtime-rpms.sh', 'prepare-yocto.sh', 'checkout.py', 'check-runtime-graph.py', 'record-runtime-rpms.py')})


def input_key(expected):
    return hashlib.sha256(encoded(expected)).hexdigest()


def manifest_key(expected):
    return f'{PREFIX}/{input_key(expected)}/manifest.json'


def verify_bundle(bundle, expected):
    rows = (bundle / 'SHA256SUMS').read_text().splitlines()
    checksums = {}
    for row in rows:
        match = re.fullmatch(r'([0-9a-f]{64})  (' + '|'.join(re.escape(name) for name in FILES) + ')', row)
        if not match or match[2] in checksums:
            raise ValueError('Invalid runtime RPM checksum inventory')
        checksums[match[2]] = match[1]
    if set(checksums) != set(FILES):
        raise ValueError('Incomplete runtime RPM checksum inventory')
    for name, checksum in checksums.items():
        path = bundle / name
        if path.is_symlink() or not path.is_file() or digest(path) != checksum:
            raise ValueError(f'runtime RPM checksum mismatch: {name}')
    if json.loads((bundle / 'build-versions.json').read_text())['yocto'] != expected['yocto']:
        raise ValueError('runtime RPM QLI source lock mismatch')
    return checksums


class S3:
    def __init__(self, bucket):
        if not re.fullmatch(r'[a-z0-9][a-z0-9.-]+', bucket):
            raise ValueError('Set PACKAGES_S3_BUCKET to the existing package bucket')
        self.bucket = bucket

    def get(self, key, target):
        result = subprocess.run(['aws', 's3api', 'get-object', '--bucket', self.bucket,
                                 '--key', key, str(target)], capture_output=True, text=True)
        if result.returncode:
            # AccessDenied, expired credentials and transport failures must not
            # turn into an expensive, misleading cache miss.
            if '(NoSuchKey)' in result.stderr:
                return False
            raise RuntimeError('S3 runtime RPM download failed: ' + result.stderr.strip())
        return True

    def put_blob(self, key, path):
        # aws s3 cp supports multipart upload for runtime RPM installers over 5 GiB.
        subprocess.run(['aws', 's3', 'cp', str(path), f's3://{self.bucket}/{key}',
                        '--only-show-errors', '--cache-control', 'max-age=31536000, immutable'], check=True)

    def create_manifest(self, key, path):
        # Publish the small manifest last. Concurrent builders keep the first
        # complete runtime RPM for these inputs; no mutable "latest" pointer.
        result = subprocess.run(['aws', 's3api', 'put-object', '--bucket', self.bucket,
                                 '--key', key, '--body', str(path), '--if-none-match', '*',
                                 '--content-type', 'application/json'], capture_output=True, text=True)
        if result.returncode:
            if '(PreconditionFailed)' in result.stderr:
                return False
            raise RuntimeError('S3 runtime RPM publication failed: ' + result.stderr.strip())
        return True


def restore(composer, bundle, s3, use_local=True):
    expected = inputs(composer)
    key = manifest_key(expected)
    pin = json.loads((composer / 'versions.json').read_text()).get('qli_runtime')
    if pin and (pin.get('manifest_key') != key or not re.fullmatch(r'[0-9a-f]{64}', pin.get('sha256', ''))):
        raise ValueError('Pinned runtime RPM does not match current runtime RPM build inputs')
    bundle.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=bundle.parent) as directory:
        staging = Path(directory)
        manifest_file = staging / 'manifest.json'
        if not s3.get(key, manifest_file):
            if pin:
                raise ValueError('Pinned runtime RPM is missing from S3; refusing to rebuild it')
            return False
        if pin and digest(manifest_file) != pin['sha256']:
            raise ValueError('Pinned runtime RPM manifest checksum mismatch')
        manifest = json.loads(manifest_file.read_text())
        if manifest.get('inputs') != expected or set(manifest.get('files', {})) != set(FILES):
            raise ValueError('Shared runtime RPM inputs or inventory mismatch')
        for name, checksum in manifest['files'].items():
            if not isinstance(checksum, str) or not re.fullmatch(r'[0-9a-f]{64}', checksum):
                raise ValueError('Invalid shared runtime RPM checksum')
            cached = bundle / name
            if use_local and cached.is_file() and not cached.is_symlink() and digest(cached) == checksum:
                # Reuse the verified local cache without downloading a large
                # installer on every job. A hard link keeps staging inexpensive.
                os.link(cached, staging / name)
            elif not s3.get(f'{PREFIX}/objects/{checksum}/{name}', staging / name):
                raise ValueError('Shared runtime RPM artifact missing')
        (staging / 'SHA256SUMS').write_text(''.join(
            f'{manifest["files"][name]}  {name}\n' for name in FILES))
        verify_bundle(staging, expected)
        # No installer is made available until every member has been verified.
        bundle.mkdir(exist_ok=True)
        for name in (*FILES, 'SHA256SUMS', 'manifest.json'):
            os.replace(staging / name, bundle / name)
        (bundle / 'runtime-pin.json').write_bytes(encoded({'qli_runtime': dict(
            manifest_key=key, sha256=digest(bundle / 'manifest.json'))}))
    print(f'Using shared runtime RPM s3://{s3.bucket}/{key}')
    return True


def publish(composer, bundle, s3):
    expected = inputs(composer)
    if json.loads((composer / 'versions.json').read_text()).get('qli_runtime'):
        raise ValueError('Pinned runtime bundles are downloaded, never republished')
    checksums = verify_bundle(bundle, expected)
    manifest = dict(inputs=expected, files=checksums)
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / 'manifest.json'
        path.write_bytes(encoded(manifest))
        for name in FILES:
            s3.put_blob(f'{PREFIX}/objects/{checksums[name]}/{name}', bundle / name)
        s3.create_manifest(manifest_key(expected), path)
    # Also resolve concurrent publication: every repository uses the winner.
    # This read verifies the actual stored bytes, not just local upload inputs.
    if not restore(composer, bundle, s3, use_local=False):
        raise ValueError('Published runtime RPM manifest disappeared')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('key', 'restore', 'publish', 'ensure', 'verify'))
    parser.add_argument('composer', type=Path)
    parser.add_argument('bundle', type=Path)
    args = parser.parse_args()
    if args.action == 'key':
        print(input_key(inputs(args.composer)))
    elif args.action == 'verify':
        verify_bundle(args.bundle, inputs(args.composer))
    else:
        s3 = S3(os.environ.get('PACKAGES_S3_BUCKET', ''))
        if args.action == 'restore':
            if not restore(args.composer, args.bundle, s3):
                raise SystemExit(3)  # Only this status permits a bootstrap build.
        elif args.action == 'publish':
            publish(args.composer, args.bundle, s3)
        elif not restore(args.composer, args.bundle, s3):
            publish(args.composer, args.bundle, s3)


if __name__ == '__main__':
    main()
