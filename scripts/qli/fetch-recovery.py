#!/usr/bin/env python3
"""Stage a checksum-pinned official Ubuntu recovery image; does not flash."""
import json
from pathlib import Path
import sys
from assets import asset_path, fetch

config=json.loads(Path(sys.argv[1]).read_text())
asset=config['recovery_images'][sys.argv[2]]
directory=Path(sys.argv[3]); directory.mkdir(parents=True,exist_ok=True)
fetch(directory,asset)
path=asset_path(directory,asset)
Path(str(path)+'.sha256').write_text(f'{asset["sha256"]}  {path.name}\n')
print(path)
