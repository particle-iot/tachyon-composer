# QLI hardware validation — September 15, 2026

Fixture: Embroid `head2-tachyon`, target `qcm6490`, NA formfactor_dvt.
Fresh-flashed image:
`tachyon-qli-2.0-NA-headless-formfactor_dvt-1.4.0-dev+build.350ff22.zip`.
SHA-256: `2356a4eb5811ac0fadb29cffd1d5e3090925f3fb62f6cf5eb8178e218edb1c6f`.
Kernel: `6.8.0-1058-particle`, package `6.8.0-1058.59+particle8`.

The flash used the previously authorized direct Particle CLI on head2-pi
while Embroid was being updated. Subsequent device checks use Embroid ADB.
At 07:15 UTC, Embroid reported `qcm6490-adb` as `peripheral_offline` for both
status and a read-only exec request; reconnect returned `not_found`.
Direct ADB polling was stopped. The target-owned soak was left running.

## Completed checks

| Check | Result |
| --- | --- |
| Fresh flash and boot | Particle flash completed successfully; ADB, SSH key login, Wi-Fi and cellular returned. No failed systemd units. |
| Partition layout | All 86 partition records match the original Ubuntu 24.04 baseline, including labels, starts, sizes, sector sizes and UUIDs. |
| UFS/GPT preservation | All seven LUN capacities and logical sector sizes are unchanged. Primary and backup GPT byte hashes match before/after flashing. |
| Protected provisioning data | `fsc`, `fsg`, `nvdata1` and `nvdata2` hashes match the original Ubuntu backups. Persist retains its original filesystem UUID. |
| Persist/TEE mount | Persist formatter and repartition units are masked; formatter helper is absent. TEE bind-mounts the existing persist filesystem. |
| Modem firmware parity | All 293 files inside NA NON-HLOS, including modem and carrier MCFG files, match Ubuntu 24.04 1.2.24. FAT container metadata differs. |
| GPU | Freedreno FD643, GLES 3.2, Mesa 26.0.5; hardware render/readback passed. |
| Audio streams | Physical playback pointer advanced; onboard mic selected; 96,000 stereo capture frames delivered at 48 kHz. No audio recording retained. |
| Short combined load | 20-second CPU/GPU/storage trial passed: 610 GPU frames at 1024×1024; two 64 MiB storage writes with checksum verification; highest sampled temperature 44.6°C. |
| Wi-Fi link-loss recovery | Disabling Wi-Fi moved the default route to cellular; HTTPS returned 200. Re-enabling Wi-Fi restored its preferred route and HTTPS. |
| Modem service restart | ModemManager/rmtfs stop/start restored a running modem and cellular HTTPS within 25 seconds during the soak. |
| BLE | Paired and bonded with a temporary Pi GATT server; characteristic reads and writes reached the peer. Two reconnects resolved services and read the expected value. Temporary bonds and advertising were removed. |
| Battery telemetry | Battery reported present, charging and healthy, with capacity/temperature values; USB reported online at 5 V. Physical power-source transitions were not tested. |

Runtime modem activity can update `modemst1/2`; persist also receives normal
filesystem writes. These are not byte-immutable partitions. No NV or persist
restore, formatting, GPT rewrite or UFS geometry provisioning was performed.
The flash tool selected the existing boot LUN. Boot payloads retain the BP
artifact's signatures; they are not byte-identical to Ubuntu's re-signed blobs.
Native QLI modem services differ from Ubuntu's legacy RFS/Particle RIL userspace.

## Findings and pending checks

- **WAN failover limitation:** blocking upstream Wi-Fi traffic while retaining
  association left the default route on Wi-Fi. Default HTTPS timed out;
  explicitly bound cellular HTTPS succeeded. NetworkManager connectivity
  checking is disabled. Temporary firewall rules were removed and ordinary
  connectivity restored.
- **Audible audio remains unconfirmed:** three quiet rising tones were played;
  onboard-mic capture showed weak matching frequency components. This does not
  establish audible output quality or acoustic fidelity.
- **One-hour soak result pending:** started at 06:58:29 UTC as
  `qli-validation-soak.service`. The last retained sample at 522 seconds showed
  a maximum temperature of 51.2°C. Collection must use Embroid ADB when available;
  do not treat a running test as a pass.
- **Suspend/resume and ten cold boots remain pending.** Run these after collecting
  the soak result, then repeat the partition and kernel-log checks.
- Early AudioReach status-query timeout and occasional probe messages remain;
  actual audio streams passed. Existing early Bluetooth/USB messages were also
  observed. No additional kernel errors appeared in the collected load/network
  test interval. Full-duration logs remain to be collected.
- `nokaslr` remains necessary to avoid the observed kernel/RMTFS reservation
  overlap. Display, Vulkan, classic Bluetooth/audio, physical battery transitions,
  SMS, voice, SIM switching and full Particle RIL integration remain unvalidated.

## Build and release verification

Both regional images built and passed full archive checks locally. Fourteen
local tests and Actionlint passed. [PR #88](https://github.com/particle-iot/tachyon-composer/pull/88)
targets the separate `qli-2.0` branch. Its
[successful CI run](https://github.com/particle-iot/tachyon-composer/actions/runs/34939083117)
built and uploaded complete NA and RoW Linux ZIPs at
`1.4.0-dev+build.33e92e9`, plus release metadata. Both published image URLs were
checked successfully. The flashed image precedes CI/build-documentation changes;
the on-device diagnostic scripts were copied separately.

The merge workflow creates `qli-2.0/1.4.0` initially and advances only the QLI
stream. It dispatches image builds and publishes versioned assets, a GitHub
Release and `meta/tachyon-qli-latest.json`. Version selection and stream isolation
have automated tests. No release tag has been created or published as part of
this validation; end-to-end tag publication remains for the first approved merge.

Private raw logs, partition snapshots and backups are under
`.tmp/qli/audit-20260915/` and `.tmp/qli/backups/` on the validation workstation;
they are deliberately excluded from Git.
