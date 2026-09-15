#!/usr/bin/env bash
# Image composition dependencies, never a prerequisite of component RPM builds.
set -euo pipefail
project=$(cd "$(dirname "$0")/../.." && pwd)
bash "$project/scripts/qli/prepare-yocto.sh" "${1:?composer versions.json}" "${2:?separate runtime Yocto workspace}"
cd "$2"
# Do not mix SDK-only library package changes with image runtime RPMs.
[[ ! -f .particle-sdk-workspace ]] || { echo 'Use a separate runtime workspace' >&2; exit 1; }
touch .particle-runtime-workspace
cat > meta-qcom/ci/particle-runtime-rpms.yml <<'YAML'
header:
  version: 14
local_conf_header:
  particle-runtime-rpms: |
    PACKAGE_CLASSES = "package_rpm"
    PACKAGECONFIG:append:pn-networkmanager = " modemmanager wwan"
    PR:append:pn-networkmanager = ".particle1"
    BB_NUMBER_THREADS = "4"
    PARALLEL_MAKE = "-j4"
    BB_DISKMON_DIRS = "STOPTASKS,${TMPDIR},10G,100K HALT,${TMPDIR},5G,50K"
YAML
configs=meta-qcom/ci/rb3gen2-core-kit.yml:meta-qcom/ci/qcom-distro.yml:meta-qcom/ci/lock.yml:meta-qcom/ci/particle-runtime-rpms.yml
kas shell "$configs" -c 'set -e; bitbake jq socat sudo libgpiod networkmanager; bitbake package-index'
