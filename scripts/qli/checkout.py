#!/usr/bin/env python3
"""Check out a source revision from the image lock without branch fallbacks."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
config = json.loads(Path(sys.argv[1]).read_text())
for key in sys.argv[2].split('.'):
    config = config[key]
revision = config['revision']
if not re.fullmatch('[0-9a-f]{40}', revision):
    raise SystemExit('Source revision must be a full commit ID')
path = Path(sys.argv[3])
if not path.exists():
    subprocess.run(['git', 'init', str(path)], check=True)
credentials = ['-c', 'credential.helper=!gh auth git-credential'] if os.environ.get('GH_TOKEN') else []
subprocess.run(['git', *credentials, '-C', str(path), 'fetch', '--depth=1', config['repository'], revision], check=True)
subprocess.run(['git', '-C', str(path), 'checkout', '--detach', revision], check=True)
if subprocess.check_output(['git', '-C', str(path), 'status', '--porcelain'], text=True).strip():
    raise SystemExit('Source checkout has untracked or modified files')
