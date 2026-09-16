# Particle stack validation — 2026-09-15

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
composition needs access to the exact private RPM artifacts; enabling the local
GitHub image workflow also requires workflow-write access. Hardware testing needs
an authenticated Embroid CLI connection to head2. Full functional radio testing additionally requires
working SIM/eSIM test resources and a peer for SMS; peripheral and power tests
need the corresponding lab equipment.

## Current status

**Not ready for image acceptance or landing.** All three component RPM builds
have passed, but their private artifacts have not been retrieved and installed
in a complete candidate image. Only LPA is currently pinned in `rpm_packages`;
the source pins now identify the successful component builds below. Missing
artifact/dependency pins intentionally stop full composition.

| Component | Source commit | RPM build | Debian build |
| --- | --- | --- | --- |
| [RIL #63](https://github.com/particle-iot-inc/particle-tachyon-ril/pull/63) | `fac5f6468caf1b784c17bcf87982f73f4e4b69db` | [428 passed](https://circleci.com/gh/particle-iot-inc/particle-tachyon-ril/428) | [424 passed](https://circleci.com/gh/particle-iot-inc/particle-tachyon-ril/424) |
| [Syscon #36](https://github.com/particle-iot-inc/particle-tachyon-syscon/pull/36) | `fe0a407fc036b9416ac2f3cf4d776cd09d0195d2` | [203 passed](https://circleci.com/gh/particle-iot-inc/particle-tachyon-syscon/203) | [201 passed](https://circleci.com/gh/particle-iot-inc/particle-tachyon-syscon/201) |
| [Particle Linux #154](https://github.com/particle-iot-inc/particle-linux/pull/154) | `0a1a7a15279e8375bf0d13dda2746792ca4f12a1` | [3628 passed](https://circleci.com/gh/particle-iot-inc/particle-linux/3628) | [ARM64 3625 passed](https://circleci.com/gh/particle-iot-inc/particle-linux/3625), [AMD64 3622 passed](https://circleci.com/gh/particle-iot-inc/particle-linux/3622) |

The minimal [SDK build 426](https://circleci.com/gh/particle-iot-inc/particle-tachyon-ril/426)
and [SDK link validation/S3 publication 427](https://circleci.com/gh/particle-iot-inc/particle-tachyon-ril/427)
passed. SDK publication checks C/C++, libsystemd and SQLite linking, AArch64 ELF
headers and S3 readback. Syscon and Particle Linux consume this shared SDK without
launching cold Yocto builds. The graph remains 153 recipes / 2,511 tasks, guarded
at 170 recipes / 2,800 tasks. See [SDK details](scripts/qli/SDK.md).

Successful component jobs retain `qli-rpm/rpm/`: the RPM, `packages.json`,
`SHA256SUMS`, dependency and file inventories. The private CircleCI artifact API
returns 404 in this session, so direct authenticated download links are still
needed. No RPM checksums have been invented or inferred from successful jobs.

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

Local validation: **39 composer tests pass**, including wrong installed versions,
modified payloads, missing shared libraries, disabled services, stale metadata,
failure-report retention and validation-report checksum protection. These tests
use fixtures where indicated; they are not substitutes for the actual RPM run.
Shell syntax and `git diff --check` pass. The ARM64 composition builder with RPM
and repository-generation tools built successfully.

## Remaining before a complete candidate run

1. Retrieve the three successful RPM artifacts and provenance/checksum manifests;
   verify bytes and package headers, then pin their exact outputs. Retrieve the
   published SDK's `sdk-pin.json` as well.
2. Build the missing runtime dependencies with `build-runtime-rpms.sh`, using the
   pinned stock QLI recipe configuration in a separate workspace. The minimal
   SDK's reduced libraries must not be installed into an image. Build and pin
   NetworkManager daemon/WWAN/Wi-Fi together with any required dependency closure.
3. Run complete NA and RoW overlay/image composition and inspect their retained
   package reports. The local component-first GitHub workflow remains unpublished:
   GitHub rejected its earlier push because the credential lacks `workflow` scope.
   That CI limitation does not prevent local composition once artifacts exist.
4. Perform the live hardware acceptance workflow below using Embroid CLI. No
   device has been flashed, reset or provisioned during this validation.

## Head2 baseline and functional acceptance

The Embroid product CLI with `--gateway broker` successfully reported ADB state
`device` and read head2's inventory. It runs QLI 2.0 and kernel ABI
`6.8.0-1058-particle`, with all three candidate Particle packages absent.
The root filesystem has about 51 GiB free. A subsequent read failed because its
actor lease was reissued without usable authority; resolve that before device
operations. CLI access and read-only inventory are not candidate acceptance.

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
PR RPMs are CircleCI artifacts; the shared SDK may be published from its PR.
No merge, RPM release upload, image release or hosted DNF feed has occurred.

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
