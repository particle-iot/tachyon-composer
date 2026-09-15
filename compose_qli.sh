#!/usr/bin/env bash
# QLI open userspace + the pinned Particle kernel. Run only in the Linux builder.
set -euo pipefail
CFG="$(realpath "${1:?versions file}")"
REGION="${2:?NA or RoW}"
VERSION="${3:?output version}"
[[ "$REGION" = NA || "$REGION" = RoW ]]
[[ "$VERSION" =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ ]]
[[ $(id -u) = 0 ]] || { echo 'Run in the privileged builder as root'; exit 1; }
PROJ="$(cd "$(dirname "$0")" && pwd)"
IN=/work/input
OUT=/work/output
mkdir -p "$OUT"
work=$(mktemp -d)
root="$work/root"
src="$work/source"
mkdir -p "$root" "$src"
cleanup() {
  local rc=$?
  trap - EXIT
  for p in "$root/dev" "$root/proc" "$root/sys" "$root" "$src"; do
    if mountpoint -q "$p"; then
      umount "$p" || { echo "ERROR: cannot unmount $p; retaining $work" >&2; exit 1; }
    fi
  done
  rm -rf "$work"
  exit "$rc"
}
trap cleanup EXIT

python3 "$PROJ/scripts/qli/rpm_repository.py" "$CFG"

# Verify every input again in the builder; do not trust fetch stamps.
python3 "$PROJ/scripts/qli/assets.py" "$CFG" "$IN"
mapfile -t inputs < <(python3 - "$CFG" "$PROJ" <<'PY'
import json,sys
sys.path.insert(0,sys.argv[2]+'/scripts/qli')
from assets import asset_path
c=json.load(open(sys.argv[1]))
for k in ('rootfs','kernel_image','kernel_modules','bp_fw'):
 print(asset_path('/work/input',c['assets'][k]))
print(c['kernel_release'])
print(c['kernel_package_version'])
PY
)
ROOTZIP=${inputs[0]}; IMAGE_DEB=${inputs[1]}; MODULES_DEB=${inputs[2]}
BPZIP=${inputs[3]}; KREL=${inputs[4]}; KVERSION=${inputs[5]}
echo "QLI 2.0 open / $KREL / $REGION / $VERSION"
for deb in "$IMAGE_DEB" "$MODULES_DEB"; do
  [[ $(dpkg-deb -f "$deb" Version) = "$KVERSION" ]]
  [[ $(dpkg-deb -f "$deb" Architecture) = arm64 ]]
  dpkg-deb -x "$deb" "$work/kernel"
done
unzip -q "$BPZIP" -d "$work/bp"
python3 - "$CFG" "$ROOTZIP" "$work/qli.img" <<'PY'
import json,shutil,sys,zipfile
c=json.load(open(sys.argv[1]))
with zipfile.ZipFile(sys.argv[2]) as z, z.open(c['rootfs_member']) as src, open(sys.argv[3],'wb') as dst:
 shutil.copyfileobj(src,dst,1024*1024)
PY
[[ $(blkid -p -s TYPE -o value "$work/qli.img") = ext4 ]]
mount -o ro,loop,noload "$work/qli.img" "$src"
# The existing Tachyon layout reserves 10 GiB for system. Leave room for modules
# and diagnostics without requiring a partition-table or UFS geometry change.
truncate -s 10G "$work/rootfs.ext4"
mkfs.ext4 -q -F -b 4096 -L tachyon-qli "$work/rootfs.ext4"
mount -o loop "$work/rootfs.ext4" "$root"
rsync -aHAX --numeric-ids "$src/" "$root/"
umount "$src"
rm -rf "$root/boot" "$root/usr/lib/modules"
mkdir -p "$root/boot" "$root/usr/lib/modules"
cp -a "$work/kernel/boot/." "$root/boot/"
cp -a "$work/kernel/lib/modules/." "$root/usr/lib/modules/"
ln -s "vmlinuz-$KREL" "$root/boot/vmlinuz"
depmod -b "$root" "$KREL"

bash "$PROJ/scripts/qli/prepare-rootfs.sh" "$root" "$work/bp/QCM6490_fw" "$CFG" "$REGION" "$VERSION" "$IN"
bash "$PROJ/scripts/qli/build-pd-mapper.sh" "$root" "$CFG" "$IN" "$work"
bash "$PROJ/scripts/qli/build-wwan.sh" "$root" "$CFG" "$IN" "$work"

# Isolated chroot support mounts; /run is intentionally private to the image.
for special in dev proc sys; do
  mount --bind "/$special" "$root/$special"
done

# Stage only the pinned RPMs. Keep this transient repository out of the image.
python3 "$PROJ/scripts/qli/rpm_repository.py" "$CFG" --cache "$IN/rpms" --destination "$root/tmp/particle-rpms"
PYTHONPATH=/work/overlay-tool python3 - "$root" "$CFG" <<'PYRPM'
import json,sys
import overlay
config=json.load(open(sys.argv[2]))
overlay.package_manager='rpm-offline'
overlay.rpm_repo='/tmp/particle-rpms'
packages=' '.join(f"{p['name']}-{p['version']}-{p['release']}.{p['architecture']}" for p in config['rpm_packages'])
overlay.install_package(sys.argv[1], '', packages)
PYRPM
stack=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["overlay_stack"])' "$CFG")
python3 /work/overlay-tool/overlay.py --mount-point "$root" --overlay-dirs /work/overlays   --package-manager rpm-offline --rpm-repo /tmp/particle-rpms --stack "$stack" apply
# The RPM database must describe the packages actually installed.
python3 "$PROJ/scripts/qli/verify-rpms.py" "$root" "$CFG"
rm -rf "$root/tmp/particle-rpms" "$root/var/cache/dnf"
for special in dev proc sys; do
  umount "$root/$special"
done


# Build the initrd with Ubuntu tools, without installing Debian packages in QLI.
cp -a "$work/kernel/boot/." /boot/
mkdir -p /lib/modules
cp -a "$work/kernel/lib/modules/$KREL" /lib/modules/
depmod "$KREL"
mkdir -p /lib/firmware /etc/initramfs-tools/hooks /etc/initramfs-tools/scripts/init-bottom /etc/initramfs-tools/conf.d
mkdir -p /etc/modprobe.d
install -m 644 "$PROJ/scripts/qli/tachyon-modules.conf" /etc/modprobe.d/tachyon.conf
cp -L "$root/usr/lib/firmware/qupv3fw.elf" /lib/firmware/qupv3fw.elf
cp "$PROJ/scripts/qli/initramfs-firmware-hook" /etc/initramfs-tools/hooks/tachyon-firmware
cp "$PROJ/scripts/qli/initramfs-vendor" /etc/initramfs-tools/scripts/init-bottom/tachyon-vendor
chmod +x /etc/initramfs-tools/hooks/tachyon-firmware /etc/initramfs-tools/scripts/init-bottom/tachyon-vendor
printf 'MODULES=most\nCOMPRESS=gzip\n' > /etc/initramfs-tools/conf.d/tachyon
printf 'RESUME=none\n' > /etc/initramfs-tools/conf.d/resume
mkinitramfs -o "$root/boot/initrd.img-$KREL" "$KREL"
ln -s "initrd.img-$KREL" "$root/boot/initrd.img"
lsinitramfs "$root/boot/initrd.img" > "$work/initramfs-files.txt"
grep -q 'lib/firmware/qupv3fw.elf' "$work/initramfs-files.txt"
grep -q 'scripts/init-bottom/tachyon-vendor' "$work/initramfs-files.txt"
grep -q 'etc/modprobe.d/tachyon.conf' "$work/initramfs-files.txt"

dtb=$(find "$work/kernel" -name qcm6490-tachyon.dtb -print -quit)
[[ -s "$dtb" ]]
[[ $(fdtget "$dtb" / model) = *Tachyon* ]]
(cd "$work"; bash "$PROJ/scripts/dtb/make-dtb-img.sh" "$dtb")
(cd "$work"; bash "$PROJ/scripts/efi/make-efi-img.sh")
mcopy -o -i "$work/efi.img" "$PROJ/scripts/qli/grub.cfg" ::/EFI/BOOT/grub.cfg

# Native aarch64 or Docker/binfmt checks the actual QLI executables and linker.
chroot "$root" /usr/bin/true
chroot "$root" /usr/bin/systemctl --version
# Exercise QLI's real kmod resolver: suppress the conflicting display module
# while retaining the Particle kernel's normal msm driver.
[[ -z "$(chroot "$root" /usr/sbin/modprobe -S "$KREL" -b --show-depends msm_display)" ]]
chroot "$root" /usr/sbin/modprobe -S "$KREL" --show-depends msm | grep -q '/msm.ko'
python3 "$PROJ/scripts/qli/validate.py" rootfs "$root" "$CFG"
sync -f "$root"
umount "$root"
rc=0; e2fsck -fy "$work/rootfs.ext4" || rc=$?
[[ "$rc" -lt 4 ]]
e2fsck -fn "$work/rootfs.ext4"

# Reuse the Particle assembly format and test-signed BP payloads, then remove
# all GPT/provisioning writes from the experiment's manifest and archive.
(cd "$work/bp"; zip -qr "$work/bootbinaries.zip" QCM6490_bootbinaries)
nonhlos=na; [[ "$REGION" = NA ]] || nonhlos=em
bash "$PROJ/scripts/assemble/make_factory_img.sh" \
  --bootbinaries "$work/bootbinaries.zip" --system "$work/rootfs.ext4" \
  --efi "$work/efi.img" --dtb_a "$work/dtb.img" \
  --core_nhlos_a "$work/bp/nonhlos-$nonhlos.img" --output "$work/factory"
name="tachyon-qli-2.0-$REGION-headless-formfactor_dvt-$VERSION"
cp "$work/initramfs-files.txt" "$work/factory/initramfs-files.txt"
python3 "$PROJ/scripts/qli/package.py" "$work/factory" "$CFG" "$REGION" "$VERSION" "$name"
(cd "$work/factory"; zip -q -r "$OUT/$name.zip.partial" .)
mv "$OUT/$name.zip.partial" "$OUT/$name.zip"
(cd "$OUT"; sha256sum "$name.zip" > "$name.zip.sha256")
cp "$work/factory/manifest.json" "$OUT/$name.manifest.json"
cp "$work/factory/flash-layout.json" "$OUT/$name.flash-layout.json"
echo "DONE: $OUT/$name.zip"
