#!/usr/bin/env python3
"""Accept CI output only when it equals the reviewed immutable artifact lock."""
import json
from pathlib import Path
import shutil
import sys
from assets import digest
from rpm_repository import validate_lock
config = json.loads(Path(sys.argv[1]).read_text())
packages = validate_lock(config)
artifacts, cache = Path(sys.argv[2]), Path(sys.argv[3])
cache.mkdir(parents=True, exist_ok=True)
for package in packages:
    matches = [p for p in artifacts.rglob(package['filename']) if digest(p) == package['sha256']]
    if not matches:
        raise SystemExit('No checksum-matching built RPM: ' + package['filename'])
    shutil.copy2(matches[0], cache / package['filename'])
print('Selected all pinned RPMs from this CI component build')
