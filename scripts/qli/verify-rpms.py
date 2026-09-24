#!/usr/bin/env python3
"""Fail image composition on installed-package, loader or service errors."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess

from assets import digest
from rpm_repository import validate_lock, distro_versions
from timezone_data import verify_timezone_data

COMPONENTS = ('particle-linux', 'particle-tachyon-ril', 'particle-tachyon-syscon', 'particle-kigen-lpa')
SERVICES = ('particle-linux', 'particle-tachyon-rild', 'particle-tachyon-gnss',
            'particle-tachyon-gnss-resume', 'particle-tachyon-syscon')
EXECUTABLES = ('/usr/bin/particle-tachyon-rild', '/usr/bin/particle-tachyon-gnss',
               '/usr/bin/particle-tachyon-ril-ctl', '/usr/bin/particle-tachyon-syscon-ctl',
               '/usr/bin/mspm0flash', '/usr/bin/lpa', '/usr/sbin/NetworkManager')


def verify(root, config, report, region, version):
    packages = validate_lock(config)

    def run(label, arguments, expected=None):
        result = subprocess.run(['chroot', str(root), *arguments], text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
        output = result.stdout.strip()
        passed = result.returncode == 0 and (expected is None or output == expected)
        report['checks'].append(dict(name=label, passed=passed, command=arguments,
                                     returncode=result.returncode, output=output[-8192:]))
        if not passed:
            raise ValueError(f'{label} failed (expected {expected!r}): {output}')

    for package in packages:
        expected = f"{package['version']}-{package['release']}.{package['architecture']}"
        run('installed:' + package['name'], ['rpm', '-q', '--qf',
            '%{VERSION}-%{RELEASE}.%{ARCH}', package['name']], expected)
    # Configuration is intentionally changed by overlays. Non-config payloads
    # must retain the hashes, modes, owners and symlinks from the actual RPMs.
    run('component-file-integrity', ['rpm', '-V', '--noconfig', *COMPONENTS])
    cli_version = next(p['version'] for p in packages if p['name'] == 'particle-linux')
    run('packaged-particle-cli', ['/usr/bin/particlectl', '--version'], cli_version)
    for executable in EXECUTABLES:
        run('loader:' + executable, ['/lib/ld-linux-aarch64.so.1', '--list', executable])
    run('networkmanager', ['/usr/sbin/NetworkManager', '--version'])
    units = [name + '.service' for name in SERVICES]
    run('service-definitions', ['/usr/bin/systemd-analyze', 'verify', '--man=no', *units])
    for unit in units:
        run('enabled:' + unit, ['/usr/bin/systemctl', 'is-enabled', unit], 'enabled')
    run('sudoers', ['/usr/sbin/visudo', '-cf', '/etc/sudoers.d/particle'])

    count = verify_timezone_data(root)
    report['checks'].append(dict(name='timezone-database', passed=True, zones_checked=count))
    # Exercise the image's libc timezone handling, including Denver's DST rule.
    # UTC alone works without tzdata and missed the original setup failure.
    for month, offset in [('01', '-0700'), ('07', '-0600')]:
        run('timezone-denver-' + month, ['/usr/bin/env', 'TZ=America/Denver',
            '/bin/date', '-d', f'2026-{month}-15 12:00:00 UTC', '+%z'], offset)

    metadata = json.loads((root / 'etc/particle/distro_versions.json').read_text())
    if metadata != distro_versions(config, region, version):
        raise ValueError('Installed distro_versions.json does not match the image/package lock')
    report['checks'].append(dict(name='image-version-metadata', passed=True))
    report['packages'] = packages


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('config', type=Path)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--region', choices=('NA', 'RoW'), required=True)
    parser.add_argument('--version', required=True)
    args = parser.parse_args()
    report = dict(scope='offline-overlay', passed=False, checks=[],
                  versions_sha256=digest(args.config), hardware_tests='not_run',
                  region=args.region, version=args.version,
                  started_at=datetime.now(timezone.utc).isoformat())
    try:
        verify(args.root, json.loads(args.config.read_text()), report, args.region, args.version)
        report['passed'] = True
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        report['finished_at'] = datetime.now(timezone.utc).isoformat()
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
