#!/usr/bin/env python3
"""Build pinned component sources with the active QLI SDK; retain reviewable RPMs."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

config_path = Path(sys.argv[1]).resolve()
config = json.loads(config_path.read_text())
workspace = Path(sys.argv[2]).resolve()
yocto = Path(sys.argv[3]).resolve()
project = Path(__file__).resolve().parents[2]
workspace.mkdir(parents=True, exist_ok=True)
output = workspace / 'artifacts'
output.mkdir()
if not (yocto / '.particle-runtime-workspace').exists():
    raise SystemExit('Build image dependencies with build-runtime-rpms.sh in a separate workspace; '
                     'SDK-only library packages must not enter the image repository')
release = yocto / 'meta-qcom-releases'
if subprocess.check_output(['git', '-C', str(release), 'rev-parse', 'HEAD'], text=True).strip() != config['yocto']['revision']:
    raise SystemExit('Active Yocto build does not match the image lock')
for name in config['components']:
    source = workspace / name
    subprocess.run([sys.executable, str(project / 'scripts/qli/checkout.py'), str(config_path),
                    'components.' + name, str(source)], check=True)
    if name == 'particle-linux':
        # Populate npm's integrity-checked cache from package-lock.json before the
        # isolated RPM build runs npm ci --offline and compiles native modules.
        subprocess.run(['npm', 'ci', '--ignore-scripts', '--no-audit', '--no-fund'], cwd=source, check=True)
    env = dict(os.environ, QLI_RELEASE_DIR=str(release), QLI_RELEASE_REVISION=config['yocto']['revision'],
               RPM_OUTPUT_DIR=str(output / name))
    subprocess.run(['bash', 'packaging/build-rpm.sh'], cwd=source, env=env, check=True)
subprocess.run([sys.executable, str(project / 'scripts/qli/package-lpa.py'), str(config_path), str(output / 'lpa')], check=True)
# Preserve Yocto's complete local repository for dependency review. Only artifacts
# explicitly promoted into rpm_packages will be installed by image composition.
shutil.copytree(yocto / 'build/tmp/deploy/rpm', output / 'yocto-rpms')
source_revisions = {}
for source in yocto.iterdir():
    if not (source / '.git').exists():
        continue
    source_revisions[source.name] = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
(output / 'yocto-source-revisions.json').write_text(json.dumps(source_revisions, indent=2) + '\n')
shutil.copy2(config_path, output / 'build-versions.json')
print(output)
