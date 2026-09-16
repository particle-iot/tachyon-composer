#!/usr/bin/env bash
# Image composition dependencies, never a prerequisite of component RPM builds.
set -euo pipefail
mode=${3:---build}
[[ $mode = --build || $mode = --graph-only ]] || { echo "Expected --build or --graph-only" >&2; exit 2; }
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
    # Runtime tools only: do not build ptest suites or a GPIO simulator kernel.
    # The candidate uses its separately pinned Particle kernel. gpiosim is not
    # shipped in this bundle; do not pull linux-qcom merely to recommend modules
    # from the unused simulator subpackage.
    DISTRO_FEATURES:remove = "ptest"
    RRECOMMENDS:libgpiod-gpiosim:remove = "kernel-module-gpio-sim kernel-module-configfs"
    PACKAGECONFIG:append:pn-networkmanager = " modemmanager wwan"
    PR:append:pn-networkmanager = ".particle1"
    BB_NUMBER_PARSE_THREADS = "8"
    BB_NUMBER_THREADS = "4"
    PARALLEL_MAKE = "-j4"
    BB_DISKMON_DIRS = "STOPTASKS,${TMPDIR},10G,100K HALT,${TMPDIR},5G,50K"
YAML
configs=meta-qcom/ci/rb3gen2-core-kit.yml:meta-qcom/ci/qcom-distro.yml:meta-qcom/ci/lock.yml:meta-qcom/ci/particle-runtime-rpms.yml
# Build only RPM outputs, not do_build's recursive runtime recommendations or
# a new image/toolchain. createrepo_c indexes the selected RPMs during composition.
kas shell "$configs" -c 'bitbake -g -c package_write_rpm jq socat sudo grep sed libgpiod networkmanager'
python3 "$project/scripts/qli/check-runtime-graph.py" build
[[ $mode = --graph-only ]] && exit 0
kas shell "$configs" -c 'bitbake -c package_write_rpm jq socat sudo grep sed libgpiod networkmanager'
