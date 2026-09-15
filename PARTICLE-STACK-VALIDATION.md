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

This workflow requires a QLI-capable Linux x86_64 build host (300 GB free),
private component input access, GitHub workflow-write access and an authenticated
Embroid connection to head2. Full functional radio testing additionally requires
working SIM/eSIM test resources and a peer for SMS; peripheral and power tests
need the corresponding lab equipment.

## Status

Implementation is a **draft**, not an accepted Particle QLI image. The Kigen LPA RPM is built and pinned; the remaining native QLI RPM outputs
have not been built/pinned, so composition intentionally fails its package preflight. The local Mac has 86 GB free; Qualcomm's locked Yocto build
requires an x86 Linux host and 300 GB free. No QLI SDK runner was supplied.
The Embroid app connector returns an authentication error, but the **Embroid
CLI works**. `embroid adb head2-tachyon status` reports `device`, and bounded
ADB commands successfully read the board inventory. Use the CLI for subsequent
head2 testing; connector reauthentication is not a hardware-access blocker.
No device was flashed, reset or provisioned during this work.

Read-only baseline (2026-09-15): head2 runs QLI 2.0 with the older particle8
kernel; the candidate Particle Linux, RIL and syscon packages are absent. The
live partition inventory was recorded, including a 1 MiB existing `misc` and
approximately 60.8 GB `system` partition. This confirms access only, not a
candidate acceptance pass. Platform PR #88 now has successful NA and RoW
image builds at commit `4bc549161db7bc123c6f1ceb0adccd8a11d5f277`;
these platform images do not contain the full-stack candidate.

## Kernel and BP input refresh

QLI now follows the kernel/BP pins merged into Ubuntu 24.04 by composer
[PR #90](https://github.com/particle-iot/tachyon-composer/pull/90), commit
`fc9097245e2d3c0c8c59ec2f809f74c525fec416`:

- Kernel image and modules: `6.8.0-1058.59+particle8` → `6.8.0-1058.59+particle9`.
  Both downloaded packages report the expected version and `arm64` architecture;
  the image, module tree and Tachyon DTB retain ABI `6.8.0-1058-particle`.
- BP firmware: `2.0.7` → `2.0.8`. All 519 ZIP entries passed CRC checks; boot
  binaries, firmware and both NA/RoW NON-HLOS images are present.
- SHA-256 hashes were calculated from all three downloaded artifacts and pinned
  in `versions.json`. The 19 composer tests and shell syntax checks pass.

No complete image build or QLI hardware validation was performed for this
refresh; the existing RPM and hardware acceptance gates still apply.

## Verified locally

- Particle Linux: Node 22 Linux typecheck/lint and 213 unit/integration tests,
  including RPM version reporting, no-feed behavior and durable bootstrap ordering.
- RIL: Linux build, 156 existing host cases, SMS/config tests, and a real-library
  PTY test for cross-process AT exclusion and reacquisition. These are host checks;
  the QLI NetworkManager activation path and modem operations need target testing.
- Syscon: Linux build, installation staging, existing upgrade/identity/shutdown
  guard tests, and all 19 deliberate mutations detected. Firmware and flasher
  downloads verified against SHA-256 pins.
- Existing Kigen 0.1.8 serial LPA and mspm0flash 0.4.3 load with the QLI reference
  rootfs's actual dynamic loader and libc. This is an ABI loading check only;
  no eSIM operation or MCU flash was performed.
- Composer: 19 flash-layout, version-stream and RPM-lock/metadata tests.
- Overlay tool: five offline installation tests, including missing dependencies
  and external-source refusal. QLI stack check excludes APT/optional installers.
- CLI: lint and 66 setup tests covering QLI selection, extent, protected-write, live misc and GPT
  comparison tests. A full existing QLI ZIP passed streamed payload checksum and
  extent validation against its saved fixture layout. This was not live attestation.

## Required before merge / image acceptance

- Build the QLI SDK and all component/utility RPMs; check package dependency names,
  native Node modules, RPM source records and repeat-build checksums.
- Add exact outputs to `versions.json` and successfully run the CI pipeline:
  local CI wiring gates both NA and RoW image jobs on the SDK/component build
  and selects artifacts by checksum. GitHub rejected the workflow push because
  the credential lacks `workflow` scope; that commit remains local. Its first
  configured-host run is pending.
- Build and test the mandatory Yocto NetworkManager daemon/WWAN/Wi-Fi RPMs.
  Kernel files still use the prior composer's file overrides; the reference RPM
  database retains the original kernel records.
- Fresh host CLI setup and on-device `particlectl setup`; password, SSH, timezone,
  Wi-Fi, eSIM bootstrap, cloud registration and container credentials survive reboot.
- Cloud connectivity, installed package/version reporting and container deployment.
- Cellular/APN activation, eSIM download/delete/enable/disable, SIM selection and
  PIN handling, SMS send/receive/storage, GNSS fixes, internal/external antenna
  settings and recovery after modem restart. Modem capability reports are not passes.
- Syscon identity, automatic service startup, shutdown notification and upgrade guards.
- ADB identity/name Tachyon; Wi-Fi; Bluetooth; GPU; audio; suspend/resume; repeated
  cold boots; CPU/GPU/storage/modem combined-load regression.
- Live GPT geometry, both GPT copies, device identity, protected provisioning
  hashes and persist UUID unchanged across flashing and bootstrap.

All hardware-dependent acceptance checks above are **not run** for this stack.
The prior bring-up image's hardware results do not satisfy these gates.

## Linked component PRs

- [overlays](https://github.com/particle-iot/tachyon-overlays/pull/44)
- [overlay-tool](https://github.com/particle-iot/tachyon-overlay-tool/pull/7)
- [particle-linux](https://github.com/particle-iot-inc/particle-linux/pull/154)
- [ril](https://github.com/particle-iot-inc/particle-tachyon-ril/pull/63)
- [syscon](https://github.com/particle-iot-inc/particle-tachyon-syscon/pull/36)
- [cli](https://github.com/particle-iot/particle-cli/pull/938)

## First candidate RPM

`particle-kigen-lpa-0.1.8-1.aarch64.rpm` was built twice with the pinned vendor
binary and fixed source timestamp. Both runs produced SHA-256
`fa874f9f91e7a73dbd8e70d21e3ccc45c37cdb93dcc81265feaec26719e401b4`.
The wrapper package records the actual aarch64/glibc dependencies and is pinned
in `versions.json`. It is a local candidate artifact, not an S3 upload or feed.
This step wraps an already built vendor binary; it does not require the QLI SDK
needed to compile the other components. No functional eSIM pass is implied.

## Component package CI (2026-09-15)

All three component PRs now add automatic CircleCI RPM builds on PR/source-branch
pushes and `main`, preserving the existing Debian builds and artifact retention:

| Component | PR | Debian build | RPM build |
| --- | --- | --- | --- |
| RIL | [#63](https://github.com/particle-iot-inc/particle-tachyon-ril/pull/63) | [passed](https://circleci.com/gh/particle-iot-inc/particle-tachyon-ril/404) | [rebuilding with host fix](https://circleci.com/gh/particle-iot-inc/particle-tachyon-ril/414) |
| Syscon | [#36](https://github.com/particle-iot-inc/particle-tachyon-syscon/pull/36) | [passed](https://circleci.com/gh/particle-iot-inc/particle-tachyon-syscon/191) | [rebuilding with host fix](https://circleci.com/gh/particle-iot-inc/particle-tachyon-syscon/200) |
| Particle Linux | [#154](https://github.com/particle-iot-inc/particle-linux/pull/154) | [arm64 passed](https://circleci.com/gh/particle-iot-inc/particle-linux/3594), [amd64 passed](https://circleci.com/gh/particle-iot-inc/particle-linux/3589) | [rebuilding with host fix](https://circleci.com/gh/particle-iot-inc/particle-linux/3616) |

The build uses each job's current checkout and a pinned composer SDK configuration.
The SDK target package names were corrected to `systemd-dev` and `libsqlite3-dev`
using the actual pinned Yocto recipes. SDK installers/configuration, RPMs,
manifests, dependencies, file lists and logs are retained as CircleCI artifacts.
Successful RPM outputs have **not** yet been verified. The supplied log for RIL
job 412 identifies the actual startup failure: Ubuntu's host `libgcc-14-dev`
is installed without `libstdc++-14-dev`. All three component CI preparation
scripts now install the matching C++ development package explicitly.

The exact OE-core sanity error was reproduced on Ubuntu 24.04 amd64 with the
pinned QLI configuration (exit 1). After installing `libstdc++-14-dev`, host
sanity and metadata parsing passed in a fresh build directory (exit 0). This
used an isolated one-recipe fixture to exercise the host check; it did not
compile a component or produce an RPM. The normal sanity checker stayed enabled.
The GitHub authentication/installer hypotheses were not the cause shown by
this log. Full SDK/RPM builds remain subject to the new CircleCI runs above.

After merge, `upload-rpm` is gated on `main` and successful builds/tests. It reuses
the Debian AWS role, `packages-particle-production` context and
`PACKAGES_S3_BUCKET`, writing under
`rpm/qli-2.0/dev/<repository>/<source-commit>/<manifest-sha256>/`. It retains
versioned RPMs, `packages.json` and `SHA256SUMS`; no hosted DNF feed is added.
Each repository's 13 publication guard/integrity tests passed locally and in CI.
Those tests use mocked AWS calls and do not demonstrate a real upload, RPM
installation or functional acceptance. No merge or RPM S3 upload has occurred.

The earlier RIL `qli-candidate` branch-only all-component job (394) is superseded
by these per-component builds. No full candidate image exists yet. Do not promote
prospective RPM pins or count the platform image's passing builds as full-stack
acceptance.

Embroid CLI now reports head2's `qcm6490-adb` binding as `peripheral_offline`;
the fixture is in use by the Mac app. No reset or flash was attempted.

An attempted LPA RPM transfer through `embroid adb ... push` returned
`invalid gateway authority envelope` with both automatic and broker routing.
ADB command execution worked at that earlier point. The package installation dry run has not
been performed, and no eSIM operation is counted as passed.

The live head2 RPM database satisfies all five LPA ELF dependency capabilities
with `libc6-2.43+git0+e9517114ac-r1.armv8_2a`. This also exposed that the initial
lock validator excluded Yocto's actual `armv8_2a` tune architecture; it now
accepts that ARM64 architecture alongside aarch64 and noarch. The composer
suite now has 20 passing tests. This dependency query is not an install test.
