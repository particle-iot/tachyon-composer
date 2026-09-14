#!/usr/bin/env bash
# Focused board integration, executed by the builder, never through target apt.
set -euo pipefail
root=${1:?root}; fw=${2:?firmware}; cfg=${3:?config}; region=${4:?region}; version=${5:?version}
inputs=${6:?pinned input directory}
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$root/etc/modprobe.d"
install -m 644 "$here/tachyon-modules.conf" "$root/etc/modprobe.d/tachyon.conf"
mkdir -p "$root/usr/lib/firmware/qcom" "$root/usr/lib/dsp" "$root/vendor" "$root/persist" "$root/boot/dtb_a"
cp -a --remove-destination "$fw/lib/firmware/qcom/." "$root/usr/lib/firmware/qcom/"
cp -a --remove-destination "$fw/usr/lib/dsp/." "$root/usr/lib/dsp/"
ln -sfn qcom/qcm6490/qupv3fw.elf "$root/usr/lib/firmware/qupv3fw.elf"
dst="$root/usr/lib/firmware/updates/ath11k/QCA6698AQ/hw2.1"
mkdir -p "$dst"
ln -sfn /vendor/wlan/amss20.bin "$dst/amss.bin"
ln -sfn /vendor/wlan/amss20.bin "$dst/amss20.bin"
ln -sfn /vendor/wlan/m3.bin "$dst/m3.bin"
ln -sfn /vendor/wlan/regdb.bin "$dst/regdb.bin"
ln -sfn /vendor/wlan/bdwlang.elf "$dst/board.bin"
# Bluetooth patch/NVM files are supplied by the same regional nonhlos image.
ln -sfn /vendor/btfw "$root/usr/lib/firmware/updates/qca"
# The Particle DTB requests a660_zap.mdt, with split signed segments. QLI's
# reference-board a660_zap.mbn does not provide this firmware lookup path.
# Use the same ZAP files as Particle's Ubuntu add-gpu-firmware overlay.
for ext in mdt b00 b01 b02; do
  install -m 644 "$inputs/a660_zap.$ext" "$root/usr/lib/firmware/updates/a660_zap.$ext"
done

python3 - "$root" "$cfg" "$region" "$version" <<'PY'
import json,pathlib,secrets,subprocess,sys
r=pathlib.Path(sys.argv[1]); config=json.load(open(sys.argv[2]))
(r/'etc/hostname').write_text('tachyon-qli\n')
hosts=r/'etc/hosts'
hosts.write_text(hosts.read_text().replace('rb3gen2-core-kit', 'tachyon-qli'))
fstab=r/'etc/fstab'
lines=[s for s in fstab.read_text().splitlines() if not (s.strip() and not s.lstrip().startswith('#') and len(s.split())>1 and s.split()[1] in ('/','/vendor','/persist','/boot/dtb_a'))]
lines += ['PARTLABEL=system / ext4 defaults,noatime,errors=remount-ro 0 1',
          'PARTLABEL=core_nhlos_a /vendor vfat ro,nosuid,nodev,noexec,nofail 0 0',
          'PARTLABEL=persist /persist ext4 defaults,nosuid,nodev,noatime,nofail 0 0',
          'PARTLABEL=dtb_a /boot/dtb_a vfat rw,nofail,x-systemd.automount,sync 0 0']
fstab.write_text('\n'.join(lines)+'\n')
(r/'etc/tachyon-qli').mkdir(exist_ok=True)
(r/'etc/tachyon-qli/build.json').write_text(json.dumps({**config,'region':sys.argv[3], 'version':sys.argv[4], 'board':'formfactor_dvt','variant':'headless'},indent=2)+'\n')
# A unique machine ID and fresh SSH host keys are generated on the board.
(r/'etc/machine-id').write_text('')
for p in (r/'etc/ssh').glob('ssh_host_*'): p.unlink()
# Disable the reference image's default root password; serial autologin provides
# lab recovery and SSH accepts keys only. The random password is not retained.
password=subprocess.run(['openssl','passwd','-6','-stdin'],input=secrets.token_urlsafe(48)+'\n',text=True,capture_output=True,check=True).stdout.strip()
shadow=r/'etc/shadow'
rows=shadow.read_text().splitlines()
rows=['root:'+password+':'+':'.join(s.split(':')[2:]) if s.startswith('root:') else s for s in rows]
shadow.write_text('\n'.join(rows)+'\n'); shadow.chmod(0o600)
PY

units="$root/etc/systemd/system"
mkdir -p "$units/multi-user.target.wants" "$units/getty.target.wants" "$units/sockets.target.wants"
ln -sfn /usr/lib/systemd/system/multi-user.target "$units/default.target"
# The 6.18 reference-board gadget configuration and display startup are replaced
# for this headless experiment. Modem/DSP consumers will be brought up separately.
for unit in weston.service weston.socket ofono.service ModemManager.service android-tools-adbd.service systemd-repart.service systemd-repart.socket; do
  ln -sfn /dev/null "$units/$unit"
done
mkdir -p "$units/serial-getty@ttyMSM0.service.d"
cat > "$units/serial-getty@ttyMSM0.service.d/lab.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear 115200 %I vt100
EOF
ln -sfn /usr/lib/systemd/system/serial-getty@.service "$units/getty.target.wants/serial-getty@ttyMSM0.service"
ln -sfn /usr/lib/systemd/system/NetworkManager.service "$units/multi-user.target.wants/NetworkManager.service"
ln -sfn /usr/lib/systemd/system/sshd.socket "$units/sockets.target.wants/sshd.socket"
cat > "$root/etc/ssh/sshd_config" <<'EOF'
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
UsePAM yes
AuthorizedKeysFile .ssh/authorized_keys
Subsystem sftp internal-sftp
EOF
mkdir -p "$root/root/.ssh"
chmod 700 "$root/root/.ssh"
# Optional public keys only. Network credentials are never baked into the ZIP.
if [[ -s /work/access/authorized_keys ]]; then
  install -m 600 /work/access/authorized_keys "$root/root/.ssh/authorized_keys"
fi
install -m 755 "$here/tachyon-adb" "$root/usr/sbin/tachyon-adb"
install -m 644 "$here/tachyon-adb.service" "$units/tachyon-adb.service"
ln -sfn ../tachyon-adb.service "$units/multi-user.target.wants/tachyon-adb.service"
mkdir -p "$root/etc/udev/rules.d"
cat > "$root/etc/udev/rules.d/90-tachyon-adb.rules" <<'EOF'
ACTION=="add", SUBSYSTEM=="udc", KERNEL=="a600000.usb", TAG+="systemd", ENV{SYSTEMD_WANTS}+="tachyon-adb.service"
ACTION=="change", SUBSYSTEM=="typec", KERNEL=="port0", RUN+="/usr/bin/systemctl --no-block restart tachyon-adb.service"
EOF
# Where provided, use QLI's own QRTR nameserver for the older Particle kernel.
if [[ -f "$root/usr/lib/systemd/system/qrtr-ns.service" ]]; then
  ln -sfn /usr/lib/systemd/system/qrtr-ns.service "$units/multi-user.target.wants/qrtr-ns.service"
fi
