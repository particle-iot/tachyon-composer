#!/usr/bin/env bash
# Build dependencies and an SDK from the exact QLI release configuration.
set -euo pipefail
config=$(realpath "${1:?composer versions.json}")
workspace=${2:?empty or previously initialized Yocto workspace}
project=$(cd "$(dirname "$0")/../.." && pwd)
[[ $(uname -s) = Linux && $(uname -m) = x86_64 ]] || { echo 'QLI SDK build requires Linux x86_64' >&2; exit 1; }
command -v kas >/dev/null
mkdir -p "$workspace"
workspace=$(realpath "$workspace")
python3 "$project/scripts/qli/checkout.py" "$config" yocto "$workspace/meta-qcom-releases"
python3 - "$config" "$workspace/meta-qcom-releases/lock.yml" <<'PY'
import hashlib,json,pathlib,sys
expected=json.load(open(sys.argv[1]))['yocto']['lock_sha256']
if hashlib.sha256(pathlib.Path(sys.argv[2]).read_bytes()).hexdigest()!=expected:
    raise SystemExit('QLI lock checksum mismatch')
PY
cd "$workspace"
kas checkout meta-qcom-releases/lock.yml
cp meta-qcom-releases/lock.yml meta-qcom/ci/lock.yml
cat > meta-qcom/ci/particle-rpms.yml <<'YAML'
header:
  version: 14
local_conf_header:
  particle-rpms: |
    PACKAGE_CLASSES = "package_rpm"
    PACKAGECONFIG:append:pn-networkmanager = " modemmanager wwan"
    PR:append:pn-networkmanager = ".particle1"
    TOOLCHAIN_TARGET_TASK:append = " libsystemd-dev sqlite3-dev"
    BB_NUMBER_THREADS = "4"
    PARALLEL_MAKE = "-j4"
    BB_DISKMON_DIRS = "STOPTASKS,${TMPDIR},10G,100K HALT,${TMPDIR},5G,50K"
YAML
# base.lock.yml, included by the pinned meta-qcom configuration, also fixes
# meta-openembedded, meta-qcom-distro and the other supporting repositories.
configs=meta-qcom/ci/rb3gen2-core-kit.yml:meta-qcom/ci/qcom-distro.yml:meta-qcom/ci/lock.yml:meta-qcom/ci/particle-rpms.yml
# meta-toolchain uses this exact distro/machine configuration and the selected
# development libraries without rebuilding the multimedia image or its kernel.
kas shell "$configs" -c 'set -e; bitbake jq socat sudo libgpiod networkmanager; bitbake meta-toolchain; bitbake package-index'
