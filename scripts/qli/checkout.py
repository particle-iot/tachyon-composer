#!/usr/bin/env python3
"""Check out a source revision from the image lock without branch fallbacks."""
import json
from pathlib import Path
import re
import subprocess
import sys
config = json.loads(Path(sys.argv[1]).read_text())[sys.argv[2]]
revision = config['revision']
if not re.fullmatch('[0-9a-f]{40}', revision):
    raise SystemExit('Source revision must be a full commit ID')
path = Path(sys.argv[3])
if not path.exists():
    subprocess.run(['git', 'init', str(path)], check=True)
subprocess.run(['git', '-C', str(path), 'fetch', '--depth=1', config['repository'], revision], check=True)
subprocess.run(['git', '-C', str(path), 'checkout', '--detach', revision], check=True)
if subprocess.check_output(['git', '-C', str(path), 'status', '--porcelain'], text=True).strip():
    raise SystemExit('Source checkout has untracked or modified files')
