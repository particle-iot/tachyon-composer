#!/usr/bin/env bash
# QLI creates these volatile directories at boot. DNF needs them in a chroot
# before the first boot because /var/log and /var/tmp are dangling symlinks.
set -euo pipefail
root=${1:?QLI root filesystem}
chroot "$root" /usr/bin/install -d -m 0755 /var/volatile/log
chroot "$root" /usr/bin/install -d -m 1777 /var/volatile/tmp
