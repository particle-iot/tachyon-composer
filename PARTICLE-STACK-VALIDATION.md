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

Implementation is a **draft**, not an accepted Particle QLI image. Exact QLI
RPM outputs have not been built/pinned, so composition intentionally fails its
package preflight. The local Mac has 86 GB free; Qualcomm's locked Yocto build
requires an x86 Linux host and 300 GB free. No QLI SDK runner was supplied.
Embroid returns `UNAUTHORIZED` / `oauth_token_invalid_grant` and requires
reauthentication. No device was flashed, reset or provisioned during this work.

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
