#!/usr/bin/env python3
"""Stage only locked QLI RPMs; no implicit package feed or skipped dependency."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
from assets import digest, fetch
from runtime_bundle import stage_runtime

REQUIRED = {'particle-linux', 'particle-tachyon-ril', 'particle-tachyon-syscon', 'particle-kigen-lpa', 'jq', 'libonig5', 'socat', 'sudo', 'grep', 'sed',
            'networkmanager-daemon', 'networkmanager-wwan', 'networkmanager-wifi', 'tzdata', 'tzdata-core'}


def validate_lock(config):
    packages = config.get('rpm_packages', [])
    if not REQUIRED.issubset({p['name'] for p in packages}):
        raise ValueError('Build and pin all QLI RPM artifacts before composition; missing: ' +
                         ', '.join(sorted(REQUIRED - {p['name'] for p in packages})))
    if not re.fullmatch(r'[0-9a-f]{40}', config['yocto']['revision']):
        raise ValueError('QLI source revision must be immutable')
    seen = set()
    for package in packages:
        for key, pattern in [('sha256', r'[0-9a-f]{64}'), ('source_revision', r'[0-9a-f]{40}')]:
            if not re.fullmatch(pattern, package[key]):
                raise ValueError(f'Invalid {key}: {package["name"]}')
        if package['qli_release_revision'] != config['yocto']['revision']:
            raise ValueError('RPM built against another QLI release')
        if package['architecture'] not in ('aarch64', 'armv8_2a', 'noarch'):
            raise ValueError('RPM must use a QLI ARM64 architecture (aarch64/armv8_2a) or noarch')
        if Path(package['filename']).name != package['filename'] or not package['filename'].endswith('.rpm'):
            raise ValueError('Invalid RPM filename')
        if package['name'] in seen:
            raise ValueError('Duplicate package pin')
        seen.add(package['name'])
    return packages


def stage(config, cache, destination):
    packages = validate_lock(config)
    cache, destination = Path(cache), Path(destination)
    cache.mkdir(parents=True, exist_ok=True)
    # Build a new repository. A stale unpinned RPM must never satisfy a dependency.
    if destination.exists():
        raise ValueError('RPM staging directory must not already exist')
    stage_runtime(config, cache, [p for p in packages if p.get('runtime_bundle')])
    destination.mkdir(parents=True)
    for package in packages:
        fetch(cache, package)
        source = cache / package['filename']
        fields = subprocess.check_output(['rpm', '-qp', '--qf', '%{NAME} %{VERSION} %{RELEASE} %{ARCH}', str(source)], text=True).split()
        expected = [package[k] for k in ('name', 'version', 'release', 'architecture')]
        if fields != expected or digest(source) != package['sha256']:
            raise ValueError('RPM metadata does not match its lock: ' + source.name)
        shutil.copy2(source, destination / source.name)
    subprocess.run(['createrepo_c', str(destination)], check=True)
    (destination / 'packages.json').write_text(json.dumps(packages, indent=2) + '\n')


def distro_versions(config, region, version):
    if region not in ('NA', 'RoW'):
        raise ValueError('Invalid region')
    return {
        'distro': {'stack': config['overlay_stack'], 'version': version, 'board': 'formfactor_dvt', 'variant': 'headless',
                   'region': region, 'platform': 'qcm6490', 'os': 'linux',
                   **{key: config[key] for key in ('distribution', 'distribution_version', 'distribution_variant')}},
        'src': {'linux-particle': config['kernel_package_version'], 'bp-fw': config['bp_fw_version'],
                'qli-rootfs-sha256': config['assets']['rootfs']['sha256'],
                'qli-yocto': config['yocto']['revision'],
                'tachyon-overlays': config['overlays']['revision'],
                'tachyon-overlay-tool': config['overlay_tool']['revision'],
                **{p['name']: f"{p['version']}-{p['release']}" for p in config.get('rpm_packages', [])}},
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('versions')
    parser.add_argument('--cache')
    parser.add_argument('--destination')
    args = parser.parse_args()
    config = json.loads(Path(args.versions).read_text())
    validate_lock(config)
    if args.destination:
        if not args.cache:
            parser.error('--cache is required for staging')
        stage(config, args.cache, args.destination)
