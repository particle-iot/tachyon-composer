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

**Not ready for hardware acceptance or landing.** All 17 pinned RPMs now install
successfully in a clean QLI filesystem with external repositories and container
networking disabled. Both regional candidate images were built locally from
composer commit `ec1a29b94d396d1a60b13c75076cae281431ae8f`; each passes all 35
composition checks and the ZIP checksum/flash-operation verifier. No candidate
image has been flashed. On-device setup passed on the existing QLI base.

The cached runtime refresh added the missing `libonig5` output. The complete
[bundle manifest](https://packages.particle.io/candidates/qli-2.0/runtime/v1/c1c47bc678ae784ec21cfbd291d62a272eb5d42b2bd61392bac8c4f5cf4cd4ca/manifest.json)
is pinned in `versions.json`, with SHA-256
`3edd3a90ff8f6eaeac15ac0dc69213eed93a96c0abbacba2d723861a7bac9114`.
The audited runtime graph contains 223 recipes / 2,478 tasks, with no image,
kernel or SDK build. Only the 13 required runtime RPMs plus four Particle RPMs
are staged in the image repository.

The installed, unmodified Embroid CLI `0.7.24+keychain.002e94ae` passed health,
repeated ADB execution and normal `adb push` after the user renewed sign-in.
All 17 RPMs are now installed on head2. On-device setup completed successfully
and the device connected to Particle cloud. The new candidate image has not
been flashed: these runtime tests use the existing particle8/BP 2.0.7 base.
A later Embroid sign-in expiration currently prevents the final second-reboot
comparison. No client patches or transfer workarounds were used in this run.

| Component | Current published source | RPM build | Debian build | Downloads |
| --- | --- | --- | --- | --- |
| [RIL #63](https://github.com/particle-iot-inc/particle-tachyon-ril/pull/63) | `74934c1e46ae0226724cb9bf8fb7de83660b7d36` | [467 passed](https://circleci.com/gh/particle-iot-inc/particle-tachyon-ril/467) | [463 passed](https://circleci.com/gh/particle-iot-inc/particle-tachyon-ril/463) | [S3 links](https://github.com/particle-iot-inc/particle-tachyon-ril/pull/63#issuecomment-5690745458) |
| [Syscon #36](https://github.com/particle-iot-inc/particle-tachyon-syscon/pull/36) | `157b47ccf8c6109ac9dff04f8b73f3e595ec5bdd` | [214 passed](https://circleci.com/gh/particle-iot-inc/particle-tachyon-syscon/214) | [212 passed](https://circleci.com/gh/particle-iot-inc/particle-tachyon-syscon/212) | [S3 links](https://github.com/particle-iot-inc/particle-tachyon-syscon/pull/36#issuecomment-5690729732) |
| [Particle Linux #154](https://github.com/particle-iot-inc/particle-linux/pull/154) | `e952c705e60f6a85cac06efd75daebe5a452c791` | [3657 passed](https://circleci.com/gh/particle-iot-inc/particle-linux/3657) | [ARM64 3654 passed](https://circleci.com/gh/particle-iot-inc/particle-linux/3654), [AMD64 3656 passed](https://circleci.com/gh/particle-iot-inc/particle-linux/3656) | [S3 links](https://github.com/particle-iot-inc/particle-linux/pull/154#issuecomment-5690740398) |

Every published artifact in these comments was downloaded and checksum-verified.
`versions.json` pins the corresponding RPM identities, source revisions and public
URLs. All 13 runtime dependencies are also pinned to the verified build outputs.

## Defects found by candidate testing

- **Syscon:** `--timeout 5 version` crashed with exit 139 on head2. PR36 fixes
  required option arguments and numeric validation. The corrected candidate
  controller now returns firmware `1.0.52` on head2 for short, long and equals
  forms. [Device output](scripts/qli/validation/head2-syscon-fixed-rpm.log).
  The full syscon RPM is now installed; its service completed successfully and
  skipped flashing because installed firmware already matches version 1.0.52.
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

## Full offline installation and regional image results

The base is the pinned QLI 2.0 build `local-20260625153136`, with kernel
particle9 and BP 2.0.8 applied during candidate composition.

| Check | Result | Evidence |
| --- | --- | --- |
| Complete offline overlay-tool DNF transaction | **PASS**, all 17 pinned RPMs; 15 installs and two NetworkManager upgrades | [Install log](scripts/qli/validation/full-offline-install-onig.log) |
| Component non-config file integrity, five service definitions/enablement, seven ELF loader checks and CLI version | **PASS** in QLI filesystem | Same install log and regional reports below |
| NA image overlay checks | **PASS**, 35 checks | [Report](scripts/qli/validation/tachyon-qli-2.0-NA-headless-formfactor_dvt-1.4.0-candidate.20260916.1.package-validation.json) |
| RoW image overlay checks | **PASS**, 35 checks | [Report](scripts/qli/validation/tachyon-qli-2.0-RoW-headless-formfactor_dvt-1.4.0-candidate.20260916.1.package-validation.json) |
| Both ZIP checksum inventories and allowed flash operations | **PASS**, check-only; no device operations | [NA](scripts/qli/validation/tachyon-qli-2.0-NA-headless-formfactor_dvt-1.4.0-candidate.20260916.1.bundle-check.txt), [RoW](scripts/qli/validation/tachyon-qli-2.0-RoW-headless-formfactor_dvt-1.4.0-candidate.20260916.1.bundle-check.txt) |
| Head2 staged package inventory | **PASS**, 17 RPM hashes and package identities verified; staging only | Saved Embroid result, exit 0; full installation not executed |
| On-device pinned RPM installation, setup and basic radio tests | **PASS within existing-base scope** | See current device results below; complete new-image acceptance remains pending |

Candidate version: `1.4.0-candidate.20260916.1`. ZIP SHA-256 values:

- NA: `0cec25ed45ac4bb679baa3523698c0a712d2ae730e6310090dffd31e82476554`
- RoW: `c66ffe7ccc3ac74920b2d53e87c7f9a8d9fa5f1b8bcccae05a2f7f0dbde7b52d`

Images are local outputs under `.tmp/qli/output/`; no image download URL or CI
image pass is claimed. Composition validated 22 allowed in-place writes. The
inherited base layout warns that `xbl_config_b` on LUNs 1 and 2 exceeds the LUN
by 64 KiB; neither candidate writes that partition. This does not establish
coverage for future B-slot updates. Live layout and provisioning preservation
still require pre-flash and post-flash verification.

The earlier missing-dependency failures are superseded by the successful full
transaction above. The archived failure logs remain diagnostic evidence.
Head2 still has kernel package particle8 and BP 2.0.7. All four Particle packages
and all 13 dependencies are installed. Device registration and the Particle
service configuration were applied. No candidate image was flashed.

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

1. Renew the Embroid session to finish the second-reboot key/certificate and
   GPT comparison. The supported CLI works; no local client modifications apply.
2. Supply approved registry credentials for the private-container test. On-device
   cloud registration does not create the CLI profile expected by the registry
   helper. Copying the user's local account token is awaiting their response.
3. Complete approved SMS send/receive, eSIM mutation, modem-reset, peripheral,
   power and combined-load tests. GPS fixes require head1's antenna; head2 has none.
4. Publish the prepared regional image CI workflow through an authorized
   workflow-write credential. PR #91 still has no image CI checks.
5. Revalidate live layout/backups and recovery, flash the exact candidate, and
   repeat acceptance on its particle9/BP 2.0.8 base. Existing-base package results
   do not establish full candidate-image acceptance or host flashing/setup.

## Current head2 device results — supported CLI run

| Check | Result | Evidence |
| --- | --- | --- |
| All 17 pinned RPMs installed via DNF, external repositories disabled | **PASS**; exact package identities and component file integrity | [Device installation](scripts/qli/validation/head2-full-installed.log) |
| Linux, RIL and GNSS service startup; D-Bus access | **PASS** | [Startup](scripts/qli/validation/head2-services-started.log) |
| `particlectl setup` | **PASS**, interactive registration completed by user, CLI exit 0 | Device `422a060000000000d0c7965f`, product `43400`; cloud status connected |
| Cloud connection and RPM/image version reporting | **PASS**, including reconnection after first reboot | [System document and status](scripts/qli/validation/head2-cloud-baseline-durable.log) |
| RIL suite `--no-esim` | **81 pass, 0 fail, 6 skip** | [Suite output](scripts/qli/validation/head2-ril-suite.log); skipped group writes to eSIM |
| Particle Linux suite | **20 pass, 0 fail, 3 skip** | [Suite output](scripts/qli/validation/head2-particle-linux-suite.log) |
| Installed RPM versions versus system document | **PASS**, independently asserted | [Version assertion](scripts/qli/validation/head2-cloud-baseline-durable.log); packaged suite's Debian-only version check skips on RPM |
| Cellular disconnect/reconnect and HTTPS bound to cellular interface | **PASS** | [Cycle and traffic](scripts/qli/validation/head2-cellular-cycle.log) |
| SIM status, current antenna configuration, eSIM listing, SMS mailbox access | **PASS**, read/query scope only | [Queries](scripts/qli/validation/head2-runtime-queries.log), [follow-up](scripts/qli/validation/head2-runtime-followup.log) |
| Syscon service/identity backup and equal-version upgrade guard | **PASS**, firmware unchanged at 1.0.52 | [Service result](scripts/qli/validation/head2-runtime-followup.log) |
| QLI release-channel behavior | **PASS**, rejects unavailable feed without claiming APT updates | Same follow-up log |
| Private registry container deployment | **INCOMPLETE**; host build/upload and cloud desired state passed, device pull failed for missing CLI account credentials | No account token copied without user response |
| GNSS position fix | **UNAVAILABLE ON HEAD2**; user confirms only head1 has a GPS antenna | [Unfiltered suite output](scripts/qli/validation/head2-gnss-suite.log) records the attempted require-fix run |
| Reboot persistence | First reboot reconnected with same reported device ID; exact key/GPT comparison **pending** after second reboot | First test marker was under volatile `/var/tmp`; corrected to `/var/lib`, then Embroid sign-in expired |

The GNSS require-fix run returned 33 pass / 8 fail / 11 skip. Seven failures
require an antenna/fix unavailable on head2. The remaining NMEA-counter check
assumes continuing raw callbacks. The native implementation deduplicates
unchanged ModemManager NMEA snapshots (`gnss_native.c`); a stationary count on
this antenna-less board is not sufficient evidence that polling stopped. This
check needs backend-aware validation and a fix-capable board; it is not counted
as passed. GNSS lifecycle/suspend checks were not run by `--quick`.

## Head2 baseline and functional acceptance

The Embroid product CLI with `--gateway broker` successfully reported ADB state
`device`, read head2's inventory, downloaded the exact candidates and ran the
DNF preflight recorded above. It runs QLI 2.0 and kernel ABI
`6.8.0-1058-particle`, with all four Particle candidate packages now installed.
The root filesystem had about 51 GiB free at capture. Device work awaits renewed sign-in. Seven
protected NV/persist partition backups were captured, transferred to a private
host directory and checksum-verified. Network credentials in that archive are
not published. Both GPT copies from all seven UFS LUNs were CRC-validated, privately downloaded
and checksum-verified as well. Revalidate the live baseline immediately before flashing.
CLI access and extracted-payload probes are not full candidate acceptance.

The following still require **complete acceptance on the newly built image**;
existing-base passes are scoped in the table above:

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
