# QLI 2.0 Open on Tachyon

This experiment runs Qualcomm Linux 2.0 open userspace with Particle's
`6.8.0-1058.59+particle8` kernel, matching modules and Tachyon DTB. It retains
Tachyon's XBL → Quectel UEFI → GRUB boot chain. It does not port Tachyon to
Qualcomm's reference image's 6.18 kernel.

## Build

Use Docker with the existing ARM64 composer builder. On an x86 host, first
build the base Dockerfile with `--platform linux/arm64` and pass its tag as
`IMAGE_TAG`. QLI's PD mapper is compiled for ARM64 inside that builder.

```sh
mkdir -p .tmp/qli/access
cp ~/.ssh/id_ed25519.pub .tmp/qli/access/authorized_keys
make test_qli
make build_qli INPUT_REGION=NA
# Or INPUT_REGION=RoW, matching the board's recorded region.
```

`QLI_VERSIONS_FILE` defaults to `versions-qli-2.0.json`.
`QLI_OUTPUT_VERSION` defaults to `0.1.0-qli.2.0.g<composer-commit>`.
Outputs and logs belong under `.tmp/qli/`, independently of the Ubuntu build.
The Ubuntu `build_24.04` interface and its versions file are unchanged.

Every downloaded input is pinned by SHA-256 and checked on every build. The
QLI ZIP contributes only its raw ext4 root filesystem. Its reference boot
firmware, EFI files, kernel/modules, DTBs, partition tables and provisioning
instructions do not enter the Tachyon package. Particle BP 2.0.7's existing
test-signed payloads are carried unchanged; this build does not re-sign them.

The composer adds the matching Particle kernel/modules, an Ubuntu-built
initramfs, Tachyon firmware links and mounts, a native QLI ADB gadget, and the
upstream PD mapper needed with the older kernel. PD mapper embeds its QRTR and
LZMA dependencies and uses QLI's libc. No Debian package installation or Ubuntu
APT overlay runs in QLI. Native NetworkManager, SSH and QLI's package tools remain.

The Particle `msm_display` blacklist is required in both the root filesystem
and initramfs. Without it, the two display modules register duplicate drivers
and this kernel can panic during device probing. The build checks QLI's actual
kmod resolver to ensure `msm_display` is suppressed and `msm` remains available.

The root image is 10 GiB and must fit the existing system partition. The
packaged manifest has explicit, finite write extents for 22 Tachyon payloads.
It contains no GPT writes, patch XML, UFS provisioning, NV writes or persist
writes. Reference-image `systemd-repart` is disabled as well.

Lab access is serial root autologin on `ttyMSM0`, USB ADB, and key-only SSH as
root. Host keys and machine ID are generated on the board. Optional public
keys are copied from `.tmp/qli/access/authorized_keys`; Wi-Fi credentials are
configured after flashing and never included in the distributable ZIP.

## Baseline and recovery on head2-pi

The Embroid resource is **head2-tachyon**, target **qcm6490**, hosted by
**head2-pi**. Use the updated Embroid inline uploader for the full ZIP. The
older CLI/runtime's 20 MiB path cannot transfer this image. There is no S3
publication or release-channel update in this workflow.

Before replacing Ubuntu, establish root access and collect the actual board
layout, region, identity, firmware version, NV/persist and network profiles.
The helper briefly stops active modem userspace services, freezes persist
while copying it, and restores those services afterwards. Keep the resulting
directory private; it includes saved network profiles.
The collector includes netplan configuration and generated NetworkManager
keyfiles under `/run`, since Ubuntu Wi-Fi profiles may not be stored in `/etc`.

```sh
embroid lease head2-tachyon --for 2h --purpose 'QLI bring-up and recovery'
embroid adb head2-tachyon push scripts/qli/collect-baseline.py /tmp/qli-collect-baseline.py
embroid adb head2-tachyon exec --timeout 120 -- \
  python3 /tmp/qli-collect-baseline.py --backup-dir /tmp/qli-baseline
embroid adb head2-tachyon exec -- \
  tar -C /tmp -czf /tmp/qli-baseline.tar.gz qli-baseline
mkdir -p .tmp/qli/backups
chmod 700 .tmp/qli/backups
embroid adb head2-tachyon pull /tmp/qli-baseline.tar.gz .tmp/qli/backups/qli-baseline.tar.gz
tar -xzf .tmp/qli/backups/qli-baseline.tar.gz -C .tmp/qli/backups
make fetch_qli_recovery INPUT_REGION=NA
```

The recovery target downloads the official Ubuntu 24.04 desktop 1.2.24 image
and verifies its published checksum. Choose the recorded board region. If
ADB is unavailable, establish serial/SSH access before proceeding; do not
substitute guessed partition geometry or a guessed region.

## Check and flash

Set `IMAGE` to the exact ZIP printed at the end of the build:

```sh
python3 scripts/qli/flash.py "$IMAGE" --check-only
python3 scripts/qli/flash.py "$IMAGE" \
  --baseline .tmp/qli/backups/qli-baseline/baseline.json \
  --backup-dir .tmp/qli/backups/qli-baseline \
  --recovery-image .tmp/qli/recovery/tachyon-ubuntu-24.04-NA-desktop-1.2.24.zip
```

The preflight verifies every ZIP member, program extent and checksum, compares
the writes and region against the saved board layout, and checks the backups
and recovery image. It then passes the local ZIP to Embroid's inline upload
and `firmware.flash` path. `--boot` requests a normal power cycle only after
successful programming. Confirm fixture identity and its USB connection before
invoking it; a saved baseline is not live device attestation.

Record the Embroid operation reference and serial output. On failed or unknown
programming, keep the target in EDL and inspect the operation before another
action. If QLI programming succeeds but boot fails, save console evidence and
restore the verified recovery ZIP through Embroid:

```sh
embroid flash head2-tachyon "$RECOVERY_IMAGE" --target qcm6490 --timeout 1800 --boot
```

### Direct Particle CLI on head2-pi

While the large-file Embroid uploader is being deployed, the same validated ZIP
can be flashed with the Particle CLI installed at `/opt/particle/bin/particle`
on `head2-pi`. Add `--prepare-only` to the full preflight command above to verify
the board, backups and recovery image without invoking Embroid. Stage both ZIPs
and their checksum files in private directories under `/home/pi/qli-2.0` and
verify the transferred SHA-256 digests there.

Use a disk-backed temporary directory: the Pi's `/tmp` is only about 1 GiB.
Enter EDL, confirm the `05c6:9008` USB device, then run on the Pi:

```sh
TMPDIR=/home/pi/qli-2.0/tmp /opt/particle/bin/particle flash --tachyon "$IMAGE" \
  --yes --skip-reset --output /home/pi/qli-2.0/logs
```

Check the CLI exit status and flash log before an explicit normal power cycle.
Keep serial recording active. This direct path uses the same finite program
XML; it does not require changing the package or its partition layout.

The September 13 hardware trial connected to the lab's mixed WPA2/WPA3 network
using a 5 GHz profile with `802-11-wireless-security.pmf=1` (disabled). Automatic
SAE/PMF association failed with this userspace/firmware combination. Apply this
workaround only to the lab connection; it is not a global image setting. A
stable cloned MAC avoids the firmware's generic default address. Wi-Fi and
network credentials remain outside the distributable image.

## Acceptance

- QLI `/etc/os-release`, kernel `6.8.0-1058-particle`, matching module tree.
- Writable root filesystem; `/vendor` and `/persist` mounted correctly.
- Serial root shell and USB ADB; SSH host keys generated and key login works.
- Wi-Fi association, DHCP, DNS and SSH over the lab network.
- One normal reboot and two cold boots with networking returning each time.
- No kernel faults, filesystem errors or missing firmware required for these checks.

Capture `uname -a`, `/proc/cmdline`, `findmnt`, `systemctl --failed`, `dmesg`,
`journalctl -b`, `nmcli device status` and the build JSON alongside the image
digest and Embroid operation records. Modem, graphics, audio and full Particle
service integration are subsequent work; report their status separately.

`make test_qli` exercises the flash bounds, protected partitions, checksum
coverage, tampered payloads and image symlink resolution. Each real build also
runs native QLI executable/linker checks, inspects the initramfs and DTB,
checks ext4 twice, and validates the manifest against the vendored Particle
schemas from `https://linux-dist.particle.io/schema/`.
