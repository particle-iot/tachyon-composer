# Particle stack validation — 2026-09-16 UTC

## Candidate workflow

[PR #91](https://github.com/particle-iot/tachyon-composer/pull/91) is the draft
full-stack candidate, based on platform [PR #88](https://github.com/particle-iot/tachyon-composer/pull/88).
Neither the platform nor the component PRs must be merged to test it: check out
and build their exact candidate commits. Merge dependencies are distinct from
build inputs.

1. Finish the candidate changes and build all RPMs against the pinned QLI SDK.
   Record the exact source revisions, package metadata and artifact hashes.
2. Pin those built artifacts in the candidate and build both NA and RoW images
   with offline dependency checks. Retain images, manifests and logs as CI
   artifacts. Disable prerelease/release uploads during candidate testing.
3. Run the existing Debian checks, component tests and CLI tests against these
   revisions. Record image hashes and candidate commit IDs in the test report.
4. On head2, capture device identity, both GPT copies, protected provisioning
   hashes and persist UUID before flashing. Validate all write extents against
   the live layout, flash only allowed existing partitions and compare afterward.
5. Run every hardware acceptance item below against the actual candidate image,
   including host and on-device setup, cloud/container use, radio/eSIM/SMS/GNSS,
   syscon, peripheral, reboot and combined-load tests. Record the board region;
   testing one board does not establish hardware coverage for both regions.
6. Fix failures in the draft PRs, rebuild and repeat affected tests. An image
   change invalidates acceptance evidence for the replaced image. Mark unavailable
   cases blocked/not run, never passed.
7. Present the final candidate commits, artifact hashes and per-test results for
   user review. Do not merge PRs, tag releases or publish image/package releases
   before that review and explicit approval.

Component builds use the shared SDK in CircleCI. Building the remaining Yocto
runtime RPMs requires a Linux x86_64 build host with sufficient disk space. Image
composition needs the exact pinned RPM artifacts; enabling the local
GitHub image workflow also requires workflow-write access. Hardware testing needs
an authenticated Embroid CLI connection to head2. Full functional radio testing additionally requires
working SIM/eSIM test resources and a peer for SMS; peripheral and power tests
need the corresponding lab equipment.

## Current status

**Not ready for image acceptance or landing.** Candidate testing has found and
fixed packaging/runtime defects; full installation, regional image builds and
successful setup still remain unverified. The initial dependency bundle now supplies `socat`, `jq`, `sudo`, `grep` and
`sed`, but a new complete DNF transaction found jq's missing `libonig5` RPM.
The [cached dependency refresh, job 460](https://circleci.com/gh/particle-iot-inc/particle-tachyon-ril/460)
adds that explicit output. Its audited graph contains 223 recipes / 2,478 tasks:
one additional packaging task, with no image, kernel or SDK build.
[Actual DNF failure](scripts/qli/validation/missing-libonig.log).

| Component | Current published source | RPM build | Debian build | Downloads |
| --- | --- | --- | --- | --- |
| [RIL #63](https://github.com/particle-iot-inc/particle-tachyon-ril/pull/63) | `74934c1e46ae0226724cb9bf8fb7de83660b7d36` | [467 passed](https://circleci.com/gh/particle-iot-inc/particle-tachyon-ril/467) | [463 passed](https://circleci.com/gh/particle-iot-inc/particle-tachyon-ril/463) | [S3 links](https://github.com/particle-iot-inc/particle-tachyon-ril/pull/63#issuecomment-5690745458) |
| [Syscon #36](https://github.com/particle-iot-inc/particle-tachyon-syscon/pull/36) | `157b47ccf8c6109ac9dff04f8b73f3e595ec5bdd` | [214 passed](https://circleci.com/gh/particle-iot-inc/particle-tachyon-syscon/214) | [212 passed](https://circleci.com/gh/particle-iot-inc/particle-tachyon-syscon/212) | [S3 links](https://github.com/particle-iot-inc/particle-tachyon-syscon/pull/36#issuecomment-5690729732) |
| [Particle Linux #154](https://github.com/particle-iot-inc/particle-linux/pull/154) | `e952c705e60f6a85cac06efd75daebe5a452c791` | [3657 passed](https://circleci.com/gh/particle-iot-inc/particle-linux/3657) | [ARM64 3654 passed](https://circleci.com/gh/particle-iot-inc/particle-linux/3654), [AMD64 3656 passed](https://circleci.com/gh/particle-iot-inc/particle-linux/3656) | [S3 links](https://github.com/particle-iot-inc/particle-linux/pull/154#issuecomment-5690740398) |

Every published artifact in these comments was downloaded and checksum-verified.
`versions.json` pins the corresponding RPM identities, source revisions and public
URLs. Runtime dependencies remain unpinned pending the actual build outputs.

## Defects found by candidate testing

- **Syscon:** `--timeout 5 version` crashed with exit 139 on head2. PR36 fixes
  required option arguments and numeric validation. The corrected candidate
  controller now returns firmware `1.0.52` on head2 for short, long and equals
  forms. [Device output](scripts/qli/validation/head2-syscon-fixed-rpm.log).
  This ran the extracted controller; the full syscon package/service is pending.
- **RIL:** the previous RPM installed Debian-prefixed unit filenames, so all
  three canonical RIL/GNSS services failed to enable. [Reproduction](scripts/qli/validation/ril-unit-names.log).
  PR63 now fixes the installer; 67 packaging tests and the new RPM/DEB builds pass.
  The published RPM has SHA-256
  `e18c16a74bb836a2786c53ef37bfb6d2046ace422df3dd26b7d12e0097c26999`
  and passes actual QLI unit verification, enablement and library loading.
  [Published RPM output](scripts/qli/validation/ril-published-unit-names.log).
- **Setup:** a missing Particle daemon previously printed an error but returned
  status 0. Error propagation alone still returned 0 when offline telemetry
  failed. PR154 now preserves status 1 before telemetry. Its actual rebuilt RPM
  passes the isolated QLI/D-Bus test with container networking disabled.
  [Result](scripts/qli/validation/setup-failure-final.log),
  [reproduction](scripts/qli/validation/check-setup-failure.sh).
  All 216 Node 22 tests and CI builds pass. This tests failure handling, not
  successful cloud registration or on-device setup.
- **LPA:** the exact pinned RPM is installed on head2 using DNF with external
  repositories disabled. Package integrity and executable usage checks pass.
  [Device output](scripts/qli/validation/head2-lpa-installed.log).
  eSIM operations have not yet been tested.

The minimal [SDK build 426](https://circleci.com/gh/particle-iot-inc/particle-tachyon-ril/426)
and [SDK link validation/S3 publication 427](https://circleci.com/gh/particle-iot-inc/particle-tachyon-ril/427)
passed. SDK publication checks C/C++, libsystemd and SQLite linking, AArch64 ELF
headers and S3 readback. Syscon and Particle Linux consume this shared SDK without
launching cold Yocto builds. The graph remains 153 recipes / 2,511 tasks, guarded
at 170 recipes / 2,800 tasks. See [SDK details](scripts/qli/SDK.md).

All three package-upload/comment jobs passed. Every file was independently
read back from its automatic PR comment: 13 verified downloads total, covering
three RPMs, four DEBs, and RPM provenance/checksum manifests. PR candidates now
use public S3 URLs with the full source commit appended to filenames and a
checksum-qualified path. No CircleCI artifact token is needed.

## Candidate acceptance attempt — 2026-09-16 UTC

The base is still the pinned QLI 2.0 build `local-20260625153136`.

| Check | Result | Evidence |
| --- | --- | --- |
| Offline overlay-tool RPM installation, external repositories and container networking disabled | **FAIL**: missing socat, jq, sudo, grep, sed | [DNF log](scripts/qli/validation/candidate-offline-install.log), [reproduction script](scripts/qli/validation/check-candidate-install.sh) |
| Head2 public download and SHA-256 verification of all three PR RPMs | **PASS** | [Embroid device log](scripts/qli/validation/candidate-head2-install.log) |
| Head2 DNF installability preflight, external repositories disabled | **FAIL**: same five missing dependencies | [Embroid device log](scripts/qli/validation/candidate-head2-install.log) |
| QLI loader resolution of extracted RIL, GNSS, RIL CLI, syscon controller, flasher, LPA and Particle CLI | **PASS**, payload-only diagnostic | [ABI log](scripts/qli/validation/candidate-payload-abi.log), [reproduction script](scripts/qli/validation/check-candidate-abi.sh) |
| Packaged `particlectl --version` and `particlectl setup --help` in QLI rootfs | **PASS**, version 0.25.2; no setup execution | [ABI log](scripts/qli/validation/candidate-payload-abi.log) |
| Actual on-device setup, installed services, registration, cellular and other functional tests | **BLOCKED / NOT RUN** | Installation dependencies must be supplied first |

The runtime build script was missing `grep` and `sed`; both targets are now
included and required by the artifact lock before composition. The other three
were already targets but had never been built/pinned. NetworkManager WWAN and
GPIO runtime support also remain absent from the reference image.

The initial preflight used public S3 downloads. A local Embroid client compatibility
fix now handles the broker's implicit lease fields correctly. Keychain renewal
completed and device commands work. The separate ADB push transport rejects its
authority envelope; the supported interactive ADB CLI successfully transferred
LPA and verified its checksum. No foreign lease was broken. LPA has since been
installed; the other three Particle packages remain absent. No flashing or
bootstrap/identity changes have occurred.

## Actual QLI installation checks — 2026-09-15

Downloaded and verified the pinned QLI 2.0 reference ZIP:
`31e25f8af580319737f76e825107ab6e9f99aa4bc523b181f130ee9af4a0ac0d`.
Its rootfs reports build ID `local-20260625153136`. Read-only chroot queries
confirmed libc 2.43, libstdc++ 15.2.0, systemd/libsystemd 259.5 and SQLite 3.51.3.
Docker, Compose, UPower, ModemManager and NetworkManager daemon/nmcli/Wi-Fi are
present. `jq`, `socat`, `sudo`, `libgpiod` and NetworkManager WWAN are absent.

The pinned `particle-kigen-lpa-0.1.8-1.aarch64.rpm` has SHA-256
`fa874f9f91e7a73dbd8e70d21e3ccc45c37cdb93dcc81265feaec26719e401b4`.
Two previous builds produced that same hash. This run installed it into a
writable overlay over the read-only QLI reference rootfs, in an ARM64 Docker
container with networking disabled. It used `createrepo_c` and the pinned overlay
tool's actual `rpm-offline` installer, with all external repositories disabled.
DNF dependency resolution and transaction checks, `rpm -V`, and the QLI loader's
library resolution all **passed**. [Retained output](scripts/qli/validation/lpa-offline-install.log).

This real test first failed because QLI's `/var/log -> volatile/log` symlink
points to a directory only created at boot. `prepare-rpm-chroot.sh` now creates
the required volatile log/tmp directories before DNF runs; the install then
passed. The same preparation is wired into `compose_qli.sh`.

This is an LPA package installation/ABI pass only. No eSIM operation, full stack
overlay, regional image build or hardware acceptance pass is implied.

## Checks enforced during full overlay composition

After the offline RPM transaction and QLI overlay stack, `verify-rpms.py` checks:

- Exact installed version, release and architecture against every RPM pin.
- Particle RPM non-configuration file integrity, permissions and ownership.
- Packaged `particlectl --version` and QLI dynamic-loader resolution for RIL,
  GNSS, syscon, the flasher, LPA and NetworkManager.
- Systemd unit definitions and enabled state for all five Particle services.
- Particle sudoers syntax and exact generated image/package version metadata.

A failure stops composition. Results are written to
`<image>.package-validation.json`, including failures, and successful results
are embedded as `package-validation.json` in the factory ZIP and covered by
`SHA256SUMS`. Reports explicitly mark hardware tests `not_run`.

Local validation: **70 composer tests pass**, including wrong installed versions,
modified payloads, missing shared libraries, disabled services, stale metadata,
failure-report retention and validation-report checksum protection. These tests
use fixtures where indicated; they are not substitutes for the actual RPM run.
Shell syntax and `git diff --check` pass. The ARM64 composition builder with RPM
and repository-generation tools built successfully.

## Remaining before a complete candidate run

1. The RIL service-name fix and updated Particle Linux/syscon artifacts are built,
   downloaded, verified and pinned. Complete runtime dependency pins next.
2. Build the missing runtime dependencies with `build-runtime-rpms.sh`, using the
   pinned stock QLI recipe configuration in a separate workspace. The minimal
   SDK's reduced libraries must not be installed into an image. Build and pin
   NetworkManager daemon/WWAN/Wi-Fi together with any required dependency closure.
3. Run complete NA and RoW overlay/image composition and inspect their retained
   package reports. The updated regional GitHub workflow remains unpublished:
   GitHub rejected its earlier push because the credential lacks `workflow` scope.
   That CI limitation does not prevent local composition once artifacts exist.
4. Perform the live hardware acceptance workflow below using Embroid CLI. No
   device has been flashed, reset or provisioned during this validation.

## Head2 baseline and functional acceptance

The Embroid product CLI with `--gateway broker` successfully reported ADB state
`device`, read head2's inventory, downloaded the exact candidates and ran the
DNF preflight recorded above. It runs QLI 2.0 and kernel ABI
`6.8.0-1058-particle`, with all three candidate Particle packages absent.
The root filesystem has about 51 GiB free. Embroid access is restored. Seven
protected NV/persist partition backups were captured, transferred to a private
host directory and checksum-verified. Network credentials in that archive are
not published. Both GPT copies from all seven UFS LUNs were CRC-validated, privately downloaded
and checksum-verified as well. Revalidate the live baseline immediately before flashing.
CLI access and extracted-payload probes are not full candidate acceptance.

All of the following are **not run for the full-stack candidate**:

- Fresh host CLI and on-device setup; password, SSH keys, timezone, Wi-Fi,
  registration, eSIM bootstrap and container credentials persist after reboot.
- Cloud connectivity, installed version reporting and container deployment.
- Cellular/APN activation, eSIM operations, SIM selection/PIN, SMS storage and
  send/receive, GNSS fixes, antenna selection and modem-restart recovery.
- Syscon identity, service startup, shutdown notification and upgrade guards.
- ADB name Tachyon, Wi-Fi, Bluetooth, GPU, audio, suspend/resume, cold boots
  and CPU/GPU/storage/modem combined-load tests.
- Unchanged live GPT geometry and both GPT copies, Particle identity, protected
  provisioning hashes and persist UUID across flashing and bootstrap. Write
  bootstrap only into existing `misc`; never add/resize/format partitions.

## Package publication and related PRs

Each component retains Debian builds, adds PR/main RPM builds and gates RPM S3
uploads on successful `main` builds/tests. Uploads use the existing package AWS
context and `PACKAGES_S3_BUCKET`, under
`rpm/qli-2.0/dev/<repository>/<source-commit>/<manifest-sha256>/`.
PR RPMs and DEBs are also uploaded under `candidates/qli-2.0/` with immutable
commit/checksum-qualified URLs and automatic PR download comments. The shared
SDK is published. No merge, production package release, image release or hosted
DNF feed has occurred.

- Platform/base: [composer #88](https://github.com/particle-iot/tachyon-composer/pull/88).
  Its earlier NA/RoW build passes do not test this full stack. Kernel particle9
  and BP 2.0.8 follow the Ubuntu 24.04 updates from merged composer #90.
- Full candidate: [composer #91](https://github.com/particle-iot/tachyon-composer/pull/91).
- [Overlays #44](https://github.com/particle-iot/tachyon-overlays/pull/44).
- [Offline overlay tool #7](https://github.com/particle-iot/tachyon-overlay-tool/pull/7).
- [Particle CLI #938](https://github.com/particle-iot/particle-cli/pull/938).
- Component PR links and exact build revisions are in the current-status table.

No new Kigen PR is required by the current wrapper: it reuses the pinned Kigen
0.1.8 serial binary. Functional eSIM testing may still reveal required changes.
