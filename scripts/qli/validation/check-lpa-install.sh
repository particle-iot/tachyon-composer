#!/usr/bin/env bash
set -euo pipefail
mkdir -p /reference /scratch /target
mount -o loop,ro /inputs/reference-rootfs.ext4 /reference
mount -t tmpfs -o size=512m tmpfs /scratch
mkdir /scratch/upper /scratch/work
mount -t overlay overlay -o lowerdir=/reference,upperdir=/scratch/upper,workdir=/scratch/work /target
trap 'umount -R /target; umount /scratch; umount /reference' EXIT
mount --bind /dev /target/dev
mount -t proc proc /target/proc
bash /composer/scripts/qli/prepare-rpm-chroot.sh /target
mkdir -p /target/tmp/lpa-validation
cp /rpm/*.rpm /target/tmp/lpa-validation/
createrepo_c /target/tmp/lpa-validation
PYTHONPATH=/overlay-tool python3 - <<'PY'
import overlay
overlay.package_manager = 'rpm-offline'
overlay.rpm_repo = '/tmp/lpa-validation'
overlay.install_package('/target', '', 'particle-kigen-lpa-0.1.8-1.aarch64')
PY
chroot /target rpm -q particle-kigen-lpa
chroot /target rpm -V particle-kigen-lpa
chroot /target /lib/ld-linux-aarch64.so.1 --list /usr/bin/lpa
echo 'PASS: isolated offline LPA RPM install, file verification and loader resolution'
echo 'Hardware eSIM operations: NOT RUN'
