#!/usr/bin/env bash
set -euo pipefail
root=${1:?}; cfg=${2:?}; input=${3:?}; work=${4:?}
[[ $(cc -dumpmachine) = aarch64-* ]] || { echo 'PD mapper must be built for aarch64'; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
mapfile -t archives < <(python3 - "$cfg" "$input" "$here" <<'PY'
import json,sys
sys.path.insert(0,sys.argv[3])
from assets import asset_path
c=json.load(open(sys.argv[1]))
for k in ('qrtr_source','pd_mapper_source'):print(asset_path(sys.argv[2],c['assets'][k]))
PY
)
mkdir -p "$work/qrtr" "$work/pd-mapper"
tar -xf "${archives[0]}" --strip-components=1 -C "$work/qrtr"
tar -xf "${archives[1]}" --strip-components=1 -C "$work/pd-mapper"
q="$work/qrtr"; p="$work/pd-mapper"
# Include libqrtr and liblzma statically; the only runtime dependency is libc.
cc -O2 -Wall -I"$q/include" -o "$root/usr/bin/pd-mapper" \
  "$p/pd-mapper.c" "$p/assoc.c" "$p/json.c" "$p/servreg_loc.c" "$p/lzma_decomp.c" \
  "$q/lib/qrtr.c" "$q/lib/qmi.c" "$q/lib/logging.c" \
  -Wl,-Bstatic -llzma -Wl,-Bdynamic
mkdir -p "$root/usr/share/licenses/tachyon-pd-mapper"
cp "$q/LICENSE" "$root/usr/share/licenses/tachyon-pd-mapper/qrtr-LICENSE"
cp "$p/LICENSE" "$root/usr/share/licenses/tachyon-pd-mapper/pd-mapper-LICENSE"
sed 's+PD_MAPPER_PATH+/usr/bin+g' "$p/pd-mapper.service.in" > "$root/etc/systemd/system/pd-mapper.service"
ln -sfn ../pd-mapper.service "$root/etc/systemd/system/multi-user.target.wants/pd-mapper.service"
chroot "$root" /lib/ld-linux-aarch64.so.1 --list /usr/bin/pd-mapper
