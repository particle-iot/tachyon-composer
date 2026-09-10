#!/usr/bin/env python3
"""Offline content gate and actual-board flash-layout gate."""
import json
from pathlib import Path
import sys
from package import compare_layout


def inside(root, path):
    # Resolve absolute image symlinks relative to the image, not the builder.
    parts = list(Path(path).parts)
    pos = root
    for _ in range(100):
        if not parts:
            return pos
        part = parts.pop(0)
        if part == '/':
            pos = root
        elif part == '..':
            pos = pos.parent
            if not pos.is_relative_to(root):
                raise ValueError('Image symlink escapes root')
        else:
            pos = pos / part
            if pos.is_symlink():
                parts = list(Path(pos.readlink()).parts) + parts
                pos = pos.parent
    raise ValueError('Image symlink loop')


def rootfs(root, config):
    krel = config['kernel_release']
    for path in ('/sbin/init', '/etc/os-release', '/boot/vmlinuz', '/boot/initrd.img',
                 f'/usr/lib/modules/{krel}/modules.dep', '/usr/sbin/sshd',
                 '/usr/bin/nmcli', '/usr/lib/firmware/qupv3fw.elf',
                 '/usr/bin/adbd', '/usr/bin/pd-mapper',
                 '/etc/tachyon-qli/build.json'):
        p = inside(root, path)
        if not p.is_file() or p.stat().st_size == 0:
            raise ValueError(f'Missing/empty image content: {path}')
    if sorted(p.name for p in (root / 'usr/lib/modules').iterdir()) != [krel]:
        raise ValueError('Unexpected module releases')
    fstab = (root / 'etc/fstab').read_text()
    if 'PARTLABEL=system / ext4' not in fstab or 'PARTLABEL=core_nhlos_a /vendor' not in fstab:
        raise ValueError('Wrong root/vendor mounts')
    if (root / 'etc/systemd/system/systemd-repart.service').readlink() != Path('/dev/null'):
        raise ValueError('QLI repartitioning service must be disabled')
    print('QLI rootfs content gate passed')


if __name__ == '__main__':
    if sys.argv[1] == 'rootfs':
        rootfs(Path(sys.argv[2]).resolve(), json.loads(Path(sys.argv[3]).read_text()))
    elif sys.argv[1] == 'layout':
        writes, baseline = [json.loads(Path(p).read_text()) for p in sys.argv[2:4]]
        compare_layout(writes['partitions'], baseline)
        print('Every flash write fits the recorded board layout')
    else:
        sys.exit('Usage: validate.py rootfs ROOT CONFIG | layout IMAGE_LAYOUT BOARD_LAYOUT')
