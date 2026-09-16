# Minimal QLI SDK for component RPMs

`build-sdk.sh versions.json SDK_WORKSPACE [--graph-only]` builds only the
compiler and link-time sysroot needed by Particle Linux, RIL/GNSS and syscon.
It keeps the locked QLI release, distro, machine, target ABI and source versions.

The host package list is explicit: GCC/G++, binutils, SDK environment setup,
pkg-config and Yocto's host-package placeholder. The target package list is
libc development files, GCC runtime/C++/atomic development files, libsystemd
headers/libraries and SQLite development files. Node 22, Python, make and RPM
packaging tools run on the CI host.

The SDK does not use the general host SDK packagegroup. It does not build
QEMU, GDB, graphics tools, a kernel, an image, networking daemons or the image's
runtime utilities. SDK debug/source/documentation bundles and ptest are disabled.
The systemd recipe is configured for the SDK's link-time library use, with the
development package depending on its libraries instead of the systemd daemon.
These SDK-only library packages must not be deployed into a device image.

Every cold build first runs `bitbake -g meta-toolchain`. `check-sdk-graph.py`
requires the compiler/library recipes, rejects forbidden recipe families and
image tasks, and enforces recipe/task-count limits before compilation begins.
`--graph-only` stops after this check. The graph report is included in the
checksum-protected shared SDK bundle as `sdk-graph.json`. Component CI also
compiles and links C (libsystemd/SQLite) and C++ probes with the installed SDK
and checks that their ELF architecture is AArch64; it does not execute them on
the x86 host.

SDK assembly uses Yocto's IPK backend internally, avoiding the DNF repository
manager build closure just to assemble a sysroot. Yocto still uses `rpm-native`
for automatic file dependency scanning. Component builds still emit
native aarch64 RPMs using the host's `rpmbuild`; image dependencies still use
QLI's RPM backend. This changes SDK packaging, not the compiler/library source
pins or target ABI. The SDK-only systemd append removes declared dependencies
of unused daemon subpackages; automatic ELF library dependencies stay enabled.

## Image runtime packages are a separate build

`build-runtime-rpms.sh versions.json RUNTIME_WORKSPACE [--graph-only]` builds
jq, onig (jq’s runtime library), socat, sudo, grep, sed, libgpiod and NetworkManager with modem support. It
runs `package_write_rpm` tasks only, rather than recursive `do_build` or image/
SDK tasks. A separate graph audit rejects kernel, bootloader, graphics and SDK
work before compilation. The measured graph is **223 recipes / 2,478 tasks**,
with hard limits of 250 recipes / 2,800 tasks. Ptest suites are disabled. The optional GPIO simulator
subpackage is excluded from the runtime bundle, and its kernel-module
recommendations do not pull in a Qualcomm kernel build; images use the separately
pinned Particle kernel. Production GPIO libraries/tools remain included.

Use a separate workspace from the SDK. Stock QLI runtime library configuration
is retained; the SDK's reduced systemd libraries must never enter an image.
`record-runtime-rpms.py` records RPM identities/checksums, the QLI release and layer
source revisions, and the audited task graph. It excludes development/debug,
locale, documentation, ptest and GPIO simulator packages from the deploy bundle.

`shared-runtime.py` publishes the verified runtime bundle to the existing S3
candidate prefix using content-addressed files and a create-once input manifest.
Its input key covers the locked QLI release and build/collection scripts; updating
Particle component artifacts alone does not rebuild the runtime dependencies.
Publication reads back and verifies the stored bytes. CI publishes from a fresh
job to avoid expired OIDC credentials after compilation, then verifies public
CDN links and posts them in a separate RIL PR comment. Auth or integrity failures
must never silently trigger a cold rebuild.

For composition, pin the published manifest key and checksum in `qli_runtime`,
then mark individually reviewed `rpm_packages` entries with `runtime_bundle: true`.
`rpm_repository.py` downloads the pinned public bundle, verifies the QLI source
lock, package identities and individual checksums, and stages only those selected
RPMs. Unselected build dependencies cannot satisfy the image transaction. Archive
paths and links are never extracted; malformed or incomplete bundles fail closed.
The final DNF transaction still runs with external repositories disabled.

The shared SDK S3 input key hashes the release lock, build/setup/graph-check
scripts and kas version. Changing to this minimal profile invalidates the old
broad SDK. Source downloads and completed Yocto task outputs are cached by the
single RIL SDK producer; ordinary component builds download the verified SDK.
A cold compiler build still has real compilation cost. Graph counts verify its
scope, not its duration or successful completion.

## Measured dependency graph (2026-09-15)

A real `--graph-only` run with the pinned QLI lock on Linux x86_64 resolved
**153 recipes / 2,511 tasks**. The previous log had a 7,949-task SDK graph plus
a separate 5,568-task runtime build. Task counts are not elapsed-time estimates.
The guard allows at most 170 recipes / 2,800 tasks and rejects the unwanted
recipe families independently of those limits. The measured recipe inventory
is in `validation/sdk-graph.json`; this records metadata resolution, not a
completed SDK or successful RPM/device test.
