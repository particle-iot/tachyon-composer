#!/usr/bin/env bash
# Payload diagnostic: isolated system bus, no Particle service, no network.
# A failed setup must fail the CLI command; this is not registration acceptance.
set -euo pipefail
mkdir -p /reference /scratch /target
mount -o loop,ro /inputs/reference-rootfs.ext4 /reference
mount -t tmpfs -o size=256m tmpfs /scratch
mkdir /scratch/upper /scratch/work
mount -t overlay overlay -o lowerdir=/reference,upperdir=/scratch/upper,workdir=/scratch/work /target
cleanup() {
  local result=$?
  trap - EXIT
  if [[ -n ${bus_pid:-} ]]; then
    kill "$bus_pid" || true
    sleep 1
  fi
  umount -R /target || result=1
  umount /scratch || result=1
  umount /reference || result=1
  exit "$result"
}
trap cleanup EXIT
mount --bind /dev /target/dev
mount -t proc proc /target/proc
(cd /target && rpm2cpio /rpm/particle-linux-0.25.2-1.aarch64.rpm | cpio -idm --quiet)
mkdir -p /target/run/dbus /target/var/volatile/log /target/var/volatile/tmp
bus_pid=$(chroot /target dbus-daemon --system --fork --print-pid)
set +e
timeout 60 chroot /target /usr/bin/particlectl setup > /scratch/setup.log 2>&1
setup_rc=$?
set -e
cat /scratch/setup.log
printf 'particlectl setup exit code with daemon unavailable: %s\n' "$setup_rc"
test "$setup_rc" -eq 1
grep -q 'Could not send a message to the particle-linux service' /scratch/setup.log
echo 'PASS: unavailable daemon produces setup error and exit 1' 
