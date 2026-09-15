#!/usr/bin/env python3
"""Verify installed identities and target-side executable loading, before imaging."""
import json
from pathlib import Path
import subprocess
import sys
from rpm_repository import validate_lock
root = Path(sys.argv[1])
packages = validate_lock(json.loads(Path(sys.argv[2]).read_text()))
for package in packages:
    actual = subprocess.check_output(['chroot', str(root), 'rpm', '-q', '--qf', '%{VERSION}-%{RELEASE}.%{ARCH}', package['name']], text=True)
    expected = f"{package['version']}-{package['release']}.{package['architecture']}"
    if actual != expected:
        raise SystemExit(f'Installed package mismatch: {package["name"]}: {actual} != {expected}')
# Invoke the real packaged Node runtime, which also imports native modules.
subprocess.run(['chroot', str(root), '/usr/bin/particlectl', '--version'], check=True, timeout=60)
# QLI's dynamic loader verifies the C services against the actual target libraries.
for executable in ('particle-tachyon-rild', 'particle-tachyon-gnss', 'particle-tachyon-ril-ctl', 'particle-tachyon-syscon-ctl', 'mspm0flash', 'lpa'):
    subprocess.run(['chroot', str(root), '/lib/ld-linux-aarch64.so.1', '--list', '/usr/bin/' + executable], check=True, timeout=30)

subprocess.run(['chroot', str(root), '/lib/ld-linux-aarch64.so.1', '--list',
                '/usr/sbin/NetworkManager'], check=True, timeout=30)
subprocess.run(['chroot', str(root), '/usr/sbin/NetworkManager', '--version'],
               check=True, timeout=30)
