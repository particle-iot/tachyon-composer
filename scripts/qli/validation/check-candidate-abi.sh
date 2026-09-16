#!/usr/bin/env bash
# Diagnostic only: extract into a temporary overlay to isolate ABI failures.
# This does NOT install packages or establish setup/service/hardware acceptance.
set -euo pipefail
mkdir -p /reference /scratch /target
mount -o loop,ro /inputs/reference-rootfs.ext4 /reference
mount -t tmpfs -o size=2g tmpfs /scratch
mkdir /scratch/upper /scratch/work
mount -t overlay overlay -o lowerdir=/reference,upperdir=/scratch/upper,workdir=/scratch/work /target
trap 'umount -R /target; umount /scratch; umount /reference' EXIT
mount --bind /dev /target/dev
mount -t proc proc /target/proc
mkdir -p /target/var/volatile/tmp
for package in /rpm/*.rpm; do
  rpm -qp --requires "$package"
  (cd /target && rpm2cpio "$package" | cpio -idm --quiet)
done
for exe in /usr/bin/particle-tachyon-rild /usr/bin/particle-tachyon-gnss /usr/bin/particle-tachyon-ril-ctl /usr/bin/particle-tachyon-syscon-ctl /usr/bin/mspm0flash /usr/bin/lpa /usr/bin/particlectl; do
  test -f "/target$exe"
  echo "Checking $exe"
  chroot /target /lib/ld-linux-aarch64.so.1 --list "$exe"
done
chroot /target /usr/bin/particlectl --version
chroot /target /usr/bin/particlectl setup --help
echo 'Payload-only ABI check: not an RPM installation or hardware pass'
