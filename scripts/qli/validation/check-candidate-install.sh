#!/usr/bin/env bash
# Run inside the ARM64 composer container, with --privileged --network none.
# Mount the pinned reference rootfs directory at /inputs, composer at /composer,
# pinned overlay-tool checkout at /overlay-tool, and verified candidate RPMs at /rpm.
# The base image remains read-only. DNF failures are acceptance failures.
set -euo pipefail
mkdir -p /reference /scratch /target
mount -o loop,ro /inputs/reference-rootfs.ext4 /reference
mount -t tmpfs -o size=2g tmpfs /scratch
mkdir /scratch/upper /scratch/work
mount -t overlay overlay -o lowerdir=/reference,upperdir=/scratch/upper,workdir=/scratch/work /target
trap 'umount -R /target; umount /scratch; umount /reference' EXIT
mount --bind /dev /target/dev
mount -t proc proc /target/proc
bash /composer/scripts/qli/prepare-rpm-chroot.sh /target
mkdir -p /target/tmp/stack-validation
cp /rpm/*.rpm /target/tmp/stack-validation/
createrepo_c /target/tmp/stack-validation
PYTHONPATH=/overlay-tool python3 - <<'PYCODE'
import overlay
overlay.package_manager = 'rpm-offline'
overlay.rpm_repo = '/tmp/stack-validation'
overlay.install_package('/target', '', 'particle-kigen-lpa particle-tachyon-ril particle-tachyon-syscon particle-linux')
PYCODE
chroot /target rpm -q particle-kigen-lpa particle-tachyon-ril particle-tachyon-syscon particle-linux
