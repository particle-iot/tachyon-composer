#!/usr/bin/env python3
"""Offline content gate and actual-board flash-layout gate."""
import json
import hashlib
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
                 '/usr/bin/adbd', '/usr/bin/pd-mapper', '/usr/bin/rmtfs',
                 '/usr/bin/tqftpserv', '/usr/sbin/ModemManager',
                 '/usr/sbin/NetworkManager',
                 '/usr/lib/NetworkManager/1.56.0/libnm-wwan.so',
                 '/usr/lib/NetworkManager/1.56.0/libnm-device-plugin-wwan.so',
                 '/usr/lib/NetworkManager/1.56.0/libnm-device-plugin-wifi.so',
                 '/etc/wireplumber/wireplumber.conf.d/51-tachyon-audio.conf',
                 '/etc/systemd/system/wireplumber.service.d/tachyon.conf',
                 '/etc/tachyon-qli/build.json'):
        p = inside(root, path)
        if not p.is_file() or p.stat().st_size == 0:
            raise ValueError(f'Missing/empty image content: {path}')
    if sorted(p.name for p in (root / 'usr/lib/modules').iterdir()) != [krel]:
        raise ValueError('Unexpected module releases')
    for ext in ('mdt', 'b00', 'b01', 'b02'):
        path = inside(root, f'/usr/lib/firmware/updates/a660_zap.{ext}')
        if hashlib.sha256(path.read_bytes()).hexdigest() != config['assets'][f'gpu_zap_{ext}']['sha256']:
            raise ValueError(f'GPU ZAP firmware checksum mismatch: {path}')
    for key, name in (
        ('audio_topology', '/usr/lib/firmware/qcom/qcm6490/qcm6490-tachyon-snd-card-tplg.bin'),
        ('audio_ucm_card', '/usr/share/alsa/ucm2/conf.d/qcm6490/qcm6490-tachyon-snd-card.conf'),
        ('audio_ucm_alias', '/usr/share/alsa/ucm2/conf.d/qcm6490/qcm6490.conf'),
    ):
        path = inside(root, name)
        if hashlib.sha256(path.read_bytes()).hexdigest() != config['assets'][key]['sha256']:
            raise ValueError(f'Audio asset checksum mismatch: {path}')
    hifi = inside(root, '/usr/share/alsa/ucm2/Qualcomm/qcm6490-tachyon/HiFi.conf').read_text()
    if 'SectionDevice."HDMI"' in hifi or 'DISPLAY_PORT_RX_0' in hifi:
        raise ValueError('Headless HiFi profile must not depend on a connected display')
    if 'SectionDevice."Headphones"' not in hifi or 'SectionDevice."Mic"' not in hifi:
        raise ValueError('Missing analog audio routes')
    fstab = (root / 'etc/fstab').read_text()
    if 'PARTLABEL=system / ext4' not in fstab or 'PARTLABEL=core_nhlos_a /vendor' not in fstab:
        raise ValueError('Wrong root/vendor mounts')
    for unit in ('systemd-repart.service', 'systemd-repart.socket', 'format-tee-partition.service'):
        if (root / f'etc/systemd/system/{unit}').readlink() != Path('/dev/null'):
            raise ValueError(f'Partition-changing service must be disabled: {unit}')
    if (root / 'usr/sbin/check-tee-partition-fs.sh').exists():
        raise ValueError('Reference persist formatter must be removed')
    tee = (root / 'etc/systemd/system/var-lib-tee.mount').read_text()
    if 'RequiresMountsFor=/persist' not in tee or 'Options=bind' not in tee or 'format-tee-partition' in tee:
        raise ValueError('TEE must reuse the existing persist mount without formatting')
    # /vendor is a separate partition mounted at boot, so validate the mapping
    # without following it into the builder's filesystem.
    if (root / 'usr/lib/firmware/tachyon/modem').readlink() != Path('/vendor/modem'):
        raise ValueError('Missing Tachyon modem firmware mapping')
    for unit in ('ModemManager', 'rmtfs', 'tqftpserv'):
        enabled = f'/etc/systemd/system/multi-user.target.wants/{unit}.service'
        if not inside(root, enabled).is_file():
            raise ValueError(f'Missing/disabled modem service: {unit}')
        override = root / f'etc/systemd/system/{unit}.service'
        if override.is_symlink() and override.readlink() == Path('/dev/null'):
            raise ValueError(f'Masked modem service: {unit}')
    profile = root / 'etc/NetworkManager/system-connections/cellular.nmconnection'
    if not profile.is_file() or profile.stat().st_mode & 0o777 != 0o600:
        raise ValueError('Missing cellular profile or wrong keyfile permissions')
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
