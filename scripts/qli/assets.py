#!/usr/bin/env python3
"""Fetch pinned QLI inputs atomically, or verify the existing cache."""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote, urlparse


def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def asset_path(directory, asset):
    name = asset.get('filename') or unquote(Path(urlparse(asset['url']).path).name)
    if Path(name).name != name or name in ('', '.', '..'):
        raise ValueError('Asset filename must be a plain filename')
    return Path(directory) / name


def fetch(directory, asset):
    if not re.fullmatch('[0-9a-f]{64}', asset['sha256']):
        raise ValueError('Each asset needs a full SHA-256 pin')
    dst = asset_path(directory, asset)
    if dst.exists():
        if digest(dst) != asset['sha256']:
            raise ValueError(f'Cached asset hash mismatch: {dst}; remove it to retry')
        print(f'Verified {dst.name}', flush=True)
        return
    tmp = dst.with_name(dst.name + '.part')
    subprocess.run(['curl', '-fLsS', '--retry', '4', '--connect-timeout', '30',
                    '-C', '-', '-o', str(tmp), asset['url']], check=True)
    if digest(tmp) != asset['sha256']:
        raise ValueError(f'Download hash mismatch: {tmp}')
    tmp.replace(dst)
    print(f'Downloaded and verified {dst.name}', flush=True)


if __name__ == '__main__':
    config = json.loads(Path(sys.argv[1]).read_text())
    directory = Path(sys.argv[2])
    directory.mkdir(parents=True, exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(lambda a: fetch(directory, a), config['assets'].values()))
