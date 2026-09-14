#!/usr/bin/env bash
# QLI's daemon omits symbols needed by WWAN: build daemon and matching plugins.
set -euo pipefail
root=${1:?}; cfg=${2:?}; input=${3:?}; work=${4:?}
[[ $(cc -dumpmachine) = aarch64-* ]] || { echo 'NetworkManager requires an aarch64 builder'; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
archive=$(python3 - "$cfg" "$input" "$here" <<'PY'
import json,sys
sys.path.insert(0,sys.argv[3])
from assets import asset_path
c=json.load(open(sys.argv[1]))
print(asset_path(sys.argv[2],c['assets']['networkmanager_source']))
PY
)
[[ $(chroot "$root" /usr/sbin/NetworkManager --version) = 1.56.0 ]]
src="$work/networkmanager"
mkdir -p "$src"
tar -xf "$archive" --strip-components=1 -C "$src"
meson setup "$src/build" "$src" --prefix=/usr --libdir=/usr/lib --sysconfdir=/etc --localstatedir=/var \
  --buildtype=release -Dmodem_manager=true -Dofono=false -Dppp=false \
  -Dmobile_broadband_provider_info_database=/usr/share/mobile-broadband-provider-info/serviceproviders.xml \
  -Dpolkit=true -Dselinux=false -Dlibaudit=no -Dconcheck=false -Dovs=false \
  -Dnmcli=false -Dnmtui=false -Dnm_cloud_setup=false -Dnbft=false \
  -Dintrospection=false -Dvapi=false -Ddocs=false -Dman=false -Dtests=no \
  -Dqt=false -Dcrypto=nss -Dlibpsl=false -Dsession_tracking_consolekit=false \
  -Dsession_tracking=systemd -Dsystemd_journal=true -Difupdown=true
ninja -C "$src/build" -j4 \
  src/core/NetworkManager \
  src/core/devices/wifi/libnm-device-plugin-wifi.so \
  src/core/settings/plugins/ifupdown/libnm-settings-plugin-ifupdown.so \
  src/core/devices/wwan/libnm-wwan.so \
  src/core/devices/wwan/libnm-device-plugin-wwan.so
dest="$root/usr/lib/NetworkManager/1.56.0"
mkdir -p "$dest" "$root/usr/share/licenses/tachyon-nm-wwan"
for lib in libnm-wwan.so libnm-device-plugin-wwan.so; do
  install -m 644 "$src/build/src/core/devices/wwan/$lib" "$dest/$lib"
done
chrpath -r '$ORIGIN' "$dest/libnm-device-plugin-wwan.so"
install -m 755 "$src/build/src/core/NetworkManager" "$root/usr/sbin/NetworkManager"
install -m 644 "$src/build/src/core/devices/wifi/libnm-device-plugin-wifi.so" "$dest/"
install -m 644 "$src/build/src/core/settings/plugins/ifupdown/libnm-settings-plugin-ifupdown.so" "$dest/"
cp "$src/COPYING" "$src/COPYING.LGPL" "$root/usr/share/licenses/tachyon-nm-wwan/"
chroot "$root" /lib/ld-linux-aarch64.so.1 --list /usr/sbin/NetworkManager
chroot "$root" /lib/ld-linux-aarch64.so.1 --list /usr/lib/NetworkManager/1.56.0/libnm-device-plugin-wwan.so
