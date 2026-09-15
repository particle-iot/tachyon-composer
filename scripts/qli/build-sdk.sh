#!/usr/bin/env bash
# Minimal C/C++ SDK for Particle RPMs; no image or runtime utility build.
set -euo pipefail
config=$(realpath "${1:?composer versions.json}")
workspace=${2:?Yocto SDK workspace}
mode=${3:---build}
[[ $mode = --build || $mode = --graph-only ]] || { echo 'Expected --build or --graph-only' >&2; exit 2; }
project=$(cd "$(dirname "$0")/../.." && pwd)
bash "$project/scripts/qli/prepare-yocto.sh" "$config" "$workspace"
cd "$workspace"
[[ ! -f .particle-runtime-workspace ]] || { echo 'Use a separate SDK workspace' >&2; exit 1; }
touch .particle-sdk-workspace
mkdir -p meta-particle-sdk/conf meta-particle-sdk/recipes-core/systemd
cat > meta-particle-sdk/conf/layer.conf <<'LAYER'
BBPATH .= ":${LAYERDIR}"
BBFILES += "${LAYERDIR}/recipes-*/*/*.bbappend"
BBFILE_COLLECTIONS += "particle-sdk"
BBFILE_PATTERN_particle-sdk = "^${LAYERDIR}/"
BBFILE_PRIORITY_particle-sdk = "99"
LAYERSERIES_COMPAT_particle-sdk = "wrynose"
LAYER
cat > meta-particle-sdk/recipes-core/systemd/systemd_%.bbappend <<'RECIPE'
# BitBake follows dependencies of every package produced by a recipe, even
# those never installed in the SDK. Keep the SDK development package's library
# dependencies; unused daemon subpackages must not pull in kernel modules,
# cryptsetup, dbus, etc. Automatic ELF library dependencies remain enabled.
# This layer is SDK-only; build-runtime-rpms.sh never includes it.
# MIME databases belong to unused daemon packages, never to SDK libraries.
DEPENDS:remove = "shared-mime-info"
PACKAGE_WRITE_DEPS:remove = "shared-mime-info-native qemuwrapper-cross"
MIMEDIR = "${datadir}/particle-sdk-unused-mime"
python __anonymous () {
    for package in (d.getVar('PACKAGES') or '').split():
        d.setVar('RDEPENDS:' + package, '')
        d.setVar('RRECOMMENDS:' + package, '')
    d.setVar('RDEPENDS:' + d.getVar('PN') + '-dev', 'libsystemd libudev')
}
RECIPE
cat > meta-qcom/ci/particle-rpms.yml <<'YAML'
header:
  version: 14
target:
  - meta-toolchain
repos:
  particle-sdk:
    path: meta-particle-sdk
local_conf_header:
  particle-rpms: |
    # IPK is used only inside the relocatable SDK to avoid DNF repository
    # tooling. Yocto still uses rpm-native for automatic file dependencies. Component artifacts still use native rpmbuild; image RPMs are
    # produced separately with the stock QLI RPM backend.
    PACKAGE_CLASSES:forcevariable = "package_ipk"
    # Replace the broad SDK packagegroups (QEMU, GDB, Wayland, build systems).
    # make, Python, Node 22 and rpmbuild are supplied by the CI host.
    TOOLCHAIN_HOST_TASK = "gcc-cross-canadian-aarch64 binutils-cross-canadian-aarch64 meta-environment-rb3gen2-core-kit nativesdk-pkgconfig nativesdk-sdk-provides-dummy"
    TOOLCHAIN_TARGET_TASK = "glibc-dev libgcc-dev libstdc++-dev libatomic-dev systemd-dev libsqlite3-dev target-sdk-provides-dummy"
    SDKIMAGE_FEATURES = ""
    SDK_TOOLCHAIN_LANGS = ""
    NO_RECOMMENDATIONS = "1"
    DISTRO_FEATURES:remove = "ptest api-documentation gobject-introspection-data tpm2 debuginfod minidebuginfo"
    EXEWRAPPER_ENABLED = "False"
    # This workspace supplies link-time libraries/headers only. These packages
    # must never be used as image runtime RPMs. Avoid systemd daemon dependencies.
    PACKAGECONFIG:pn-systemd = ""
    PACKAGECONFIG:remove:pn-systemd = "openssl tpm2 cryptsetup cryptsetup-plugins efi repart"
    RDEPENDS:systemd-dev:pn-systemd = "libsystemd libudev"
    SPDX_INCLUDE_KERNEL_CONFIG = "0"
    BB_NUMBER_PARSE_THREADS = "8"
    BB_NUMBER_THREADS = "4"
    PARALLEL_MAKE = "-j4"
    BB_DISKMON_DIRS = "STOPTASKS,${TMPDIR},10G,100K HALT,${TMPDIR},5G,50K"
YAML
configs=meta-qcom/ci/rb3gen2-core-kit.yml:meta-qcom/ci/qcom-distro.yml:meta-qcom/ci/lock.yml:meta-qcom/ci/particle-rpms.yml
# Resolve and audit the complete graph before allowing any compiler work.
kas shell "$configs" -c 'bitbake -g meta-toolchain'
python3 "$project/scripts/qli/check-sdk-graph.py" build
[[ $mode = --graph-only ]] && exit 0
kas shell "$configs" -c 'bitbake meta-toolchain'
