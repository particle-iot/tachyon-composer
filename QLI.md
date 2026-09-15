# QLI 2.0 Open on Tachyon

This experiment runs Qualcomm Linux 2.0 open userspace with Particle's
`6.8.0-1058.59+particle8` kernel, matching modules and Tachyon DTB. It retains
Tachyon's XBL → Quectel UEFI → GRUB boot chain. It does not port Tachyon to
Qualcomm's reference image's 6.18 kernel.

## Build

Use Docker. `make build_qli` builds an ARM64 builder and registers ARM64
emulation on x86 Linux when needed. PD mapper compiles inside that builder.
NetworkManager and Particle RPMs require the pinned Yocto SDK build described
below; the final image checks executable loading against QLI libraries.

```sh
mkdir -p .tmp/qli/access
cp ~/.ssh/id_ed25519.pub .tmp/qli/access/authorized_keys
make test_qli
make build_qli INPUT_REGION=NA
# Or INPUT_REGION=RoW, matching the board's recorded region.
```

`QLI_VERSIONS_FILE` defaults to `versions.json`.
`QLI_OUTPUT_VERSION` defaults to the next QLI version with
`-dev+build.<composer-commit>` appended, starting at `1.4.0`.
Outputs and logs belong under `.tmp/qli/`, independently of the Ubuntu build.
The Ubuntu `build_24.04` interface is retained; supply its versions file from
the Ubuntu branch when building from this QLI branch.

Every downloaded input is pinned by SHA-256 and checked on every build. The
QLI ZIP contributes only its raw ext4 root filesystem. Its reference boot
firmware, EFI files, kernel/modules, DTBs, partition tables and provisioning
instructions do not enter the Tachyon package. Particle BP 2.0.7's existing
test-signed payloads are carried unchanged; this build does not re-sign them.

The composer adds the matching Particle kernel/modules, an Ubuntu-built
initramfs, Tachyon firmware links and mounts, a native QLI ADB gadget, and the
upstream PD mapper needed with the older kernel. PD mapper embeds its QRTR and
LZMA dependencies and uses QLI's libc. No Debian package installation or Ubuntu
APT overlay runs in QLI. The locked Yocto recipe supplies NetworkManager RPMs
with WWAN support; SSH, ModemManager and QLI's package tools remain from the
reference image.

The Particle `msm_display` blacklist is required in both the root filesystem
and initramfs. Without it, the two display modules register duplicate drivers
and this kernel can panic during device probing. The build checks QLI's actual
kmod resolver to ensure `msm_display` is suppressed and `msm` remains available.

The root image is 10 GiB and must fit the existing system partition. The
packaged manifest has explicit, finite write extents for 22 Tachyon payloads.
It contains no GPT writes, patch XML, UFS provisioning, NV writes or persist
writes. Reference-image `systemd-repart` and `format-tee-partition` are masked.
The persist-formatting helper is removed. TEE bind-mounts the existing
`/persist` filesystem; a missing or damaged filesystem is never formatted.
Root filesystem growth stays inside the existing `system` partition.

The Ubuntu 24.04 1.2.24 NA recovery image and BP 2.0.7 NA image contain
293 identical NON-HLOS files, including every modem and carrier MCFG file.
The FAT image hashes differ, so this is a file-content comparison. Boot blobs
are the BP artifact's test-signed versions; Ubuntu's composer re-signs them.
Native QLI ModemManager/rmtfs/tqftpserv differ from Ubuntu's userspace and
legacy RFS service. They use the same modem firmware and named EFS partitions;
this is not a claim that all modem userspace or Particle RIL features are identical.

Lab access is serial root autologin on `ttyMSM0`, USB ADB, and key-only SSH as
root. Host keys and machine ID are generated on the board. Optional public
keys are copied from `.tmp/qli/access/authorized_keys`; Wi-Fi credentials are
configured after flashing and never included in the distributable ZIP.
The USB product name is `Tachyon`. ADB retains Ubuntu 24.04's Particle device
ID: `422a060000000000` followed by the SoC serial as eight hexadecimal digits.
Using the raw decimal SoC serial changes the USB identity and leaves existing
Embroid ADB bindings offline even though the node and USB device are online.

## Baseline and recovery on head2-pi

The Embroid resource is **head2-tachyon**, target **qcm6490**, hosted by
**head2-pi**. Use the updated Embroid inline uploader for the full ZIP. The
older CLI/runtime's 20 MiB path cannot transfer this image. Direct Particle
CLI flashing on the Pi is also supported after the same preflight.

## PR images and releases

The release branches and tag streams are separate:

| OS | Release branch | Tags | Initial version |
| --- | --- | --- | --- |
| Ubuntu 24.04 | `main` | bare `1.2.x` | `1.2.0` |
| Ubuntu 26.04 | `26.04` | `26.04/1.3.x` | `1.3.0` |
| Qualcomm Linux 2.0 open | `qli-2.0` | `qli-2.0/1.4.x` | `1.4.0` |

Open QLI PRs against `qli-2.0`, not `main`. The PR workflow builds full
NA and RoW headless flashable Linux ZIPs, validates every archive member and
write extent, and uploads ZIP/checksum/manifest/layout artifacts to GitHub.
Same-repository PRs also publish download links under `prerelease/` when
`UPLOAD_PR_ASSETS` is enabled (the default).

Merging a PR into `qli-2.0` tags the exact merge commit and explicitly
dispatches the image build. The first release is `qli-2.0/1.4.0`; subsequent
merges increment only this stream's patch. `release:minor` and `release:major`
labels advance the QLI stream deliberately. Rerunning a merged-PR workflow
reuses its existing tag. Ubuntu tags never influence QLI version selection.

Tag builds publish both regional ZIPs under `releases/<version>/<region>/`,
per-version metadata under `meta/tachyon-<version>.json`, and a GitHub Release.
After both images and metadata succeed, `meta/tachyon-qli-latest.json` is
updated with QLI builds. `PUSH_QLI_JSON=false` disables that channel update;
`UPLOAD_TAG_ASSETS=false` leaves only downloadable GitHub build artifacts.
Ubuntu latest/stable metadata and GitHub's default latest-release marker are
not changed by this branch. Existing AWS role/bucket/CloudFront configuration
are reused. Builds use GitHub's native `ubuntu-24.04-arm` runner by default;
`QLI_BUILD_RUNNER` can select a larger runner when available.

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

## GPU firmware

The Particle DTB requests `a660_zap.mdt` and its split `.b00`, `.b01` and `.b02`
segments. These signed files come from Particle's Ubuntu `add-gpu-firmware`
overlay, pinned to commit `4bbd8a8947f30862f66c4d4faf4eac9a2c67da31` and individual
SHA-256 hashes in `versions.json`. The composer installs them under
`/usr/lib/firmware/updates/`. QLI already supplies the SQE and GMU firmware.

Without these files, `msm` creates DRM device nodes but logs
`Unable to load a660_zap.mdt` and `gpu hw init failed: -2`. Keep the
`msm_display` blacklist: the working GPU driver is `msm`.

Run `python3 gpu-smoke.py` on the target using `scripts/qli/gpu-smoke.py`.
It requires a Freedreno hardware renderer, creates a surfaceless GLES context,
renders a pixel and checks its RGBA readback. The live NA board passed with
`FD643`, OpenGL ES 3.2 and Mesa 26.0.5. Physical display output and Vulkan have
not been validated. The September 15 fresh flash of
`1.4.0-dev+build.350ff22` includes this firmware fix and the cellular/audio
integration below; its hardware checks are recorded in
[QLI-VALIDATION.md](QLI-VALIDATION.md).

For a bounded CPU, GPU readback and filesystem I/O soak, copy both
`scripts/qli/stress-smoke.py` and `scripts/qli/gpu-smoke.py` to the same target
directory and run `python3 stress-smoke.py --seconds 3600`. The soak checks
1024×1024 GLES readbacks and checksums a temporary 64 MiB file after each write.
It prints thermal/frequency samples and stops if a reported sensor reaches
90°C. This exercises GPU fill/readback, not shader or Vulkan coverage.

## Cellular modem

The Tachyon DTB requests `tachyon/modem/modem.mdt`. The composer maps this
firmware directory to `/vendor/modem`, supplied by the matching regional
Particle nonhlos image. QLI's native PD mapper, rmtfs and tqftpserv support the
modem; ModemManager owns its QRTR/QMI interface. oFono stays disabled.

The rmtfs override removes its reference-image read-only flag and uses the
existing partition labels (`-P -s`). Normal modem runtime can update its NV
partitions. No NV formatting, initialization or backup restore is performed.
The firmware mount is available before rmtfs starts. tqftpserv uses its native
firmware path translation and a private writable state directory.

GRUB passes `nokaslr` as a workaround for the current EFI memory map. A reboot
placed kernel code at `0xf86f0000`, overlapping the DT's modem RMTFS reservation
at `0xf8500000–0xf8afffff`; its reservation and driver mapping then failed.
With random placement disabled, the kernel loaded outside that range and the
modem started automatically. This disables kernel address randomization in this
lab image. A firmware reservation fix is needed before restoring KASLR.

QLI's reference NetworkManager was compiled without modem support. The pinned
Yocto recipe now builds the daemon and matching WWAN/Wi-Fi plugins with
`modemmanager wwan` enabled. Its RPM release receives a `.particle1` suffix so
DNF replaces the reference daemon instead of treating it as already installed.
The daemon, WWAN and Wi-Fi RPMs are mandatory lock entries; review and pin any
additional dependency outputs from the same build. The final image checks
loading against QLI libraries. These new RPMs have not yet been built or tested
on the board; the observations below belong to the earlier bring-up image.

The default `cellular` NetworkManager profile automatically connects using
Particle's `ksx.global.data` APN and permits roaming, matching the Ubuntu
profile. For another SIM, change `gsm.apn` with `nmcli connection modify cellular`.
A route metric of 700 keeps an ordinary Wi-Fi connection (600) preferred.
The modem's selected SIM slot and stored credentials are left intact.

```sh
mmcli -L
nmcli device status
nmcli connection show cellular
nmcli connection up cellular
# Disable automatic cellular data if desired:
nmcli connection modify cellular connection.autoconnect no
nmcli connection down cellular
```

The live NA board registered on AT&T while roaming and reported LTE/5G NR.
NetworkManager automatically established an IPv4 bearer on `qmapmux0.0`, and
HTTPS explicitly bound to that interface returned HTTP 200. Automatic modem
startup passed two normal reboots with the boot workaround. With Wi-Fi disconnected,
cellular supplied the default route and DNS, and HTTPS passed again; Wi-Fi was
then restored. This SIM/APN rejected IPv6 with `ip-version-mismatch`; IPv4
connected successfully. On the fresh September 15 image, restarting
ModemManager/rmtfs restored cellular connectivity within 25 seconds. Wi-Fi
link loss switched the default route to cellular and HTTPS passed.

An upstream-only Wi-Fi outage does not automatically switch the default route:
with association still up, default HTTPS timed out while an explicitly bound
cellular request succeeded. That earlier NetworkManager build disabled connectivity
checking, so link-loss recovery must not be mistaken for WAN health failover.
SMS, voice and SIM switching have not been validated.

## Audio

The composer installs Particle's Tachyon AudioReach topology and ALSA UCM2
files from the pinned Ubuntu audio overlay. Without the topology, the kernel
reports `qcm6490-tachyon-snd-card-tplg.bin` missing (`-2`), sound-card probing
fails, and ALSA has no cards even though the audio DSP is running.

The headless UCM patch keeps the ES8388 headphone output (`hw:0,0`) and onboard
microphone (`hw:0,2`) at 48 kHz. The upstream Ubuntu profile includes HDMI/DP
in the same HiFi verb; QLI rejects the entire profile when an unplugged display
fails PCM probing, leaving Dummy Output. This image omits that display route
from HiFi. HDMI/DP audio is not enabled by this headless configuration.

QLI's existing system-wide PipeWire 1.6.3 and WirePlumber 0.5.14 select the HiFi
profile automatically. The Ubuntu overlay's old Lua policy is not copied;
WirePlumber 0.5 uses a different configuration format. The native rule keeps UCM
and disables generic Pro Audio probing on the Tachyon card, avoiding unnecessary
PCM probes of disconnected DisplayPort hardware. A service drop-in gives
WirePlumber a private writable state directory instead of trying to write under
`/.local/state`, so normal route/volume preferences can persist.

```sh
cat /proc/asound/cards
PIPEWIRE_RUNTIME_DIR=/run/pipewire wpctl status
# Silent playback with an advancing physical PCM pointer check:
python3 audio-smoke.py
# Also test two seconds of microphone capture (statistics only, no saved audio):
python3 audio-smoke.py --capture
```

Copy `scripts/qli/audio-smoke.py` to the target before running it. Passing this
check establishes hardware stream activity and capture delivery. It does not
establish audible headphone output, microphone fidelity or HDMI/DP operation.
The live board passed default playback and capture after reboot with the final
configuration, and the disconnected-DP codec errors were absent. A single early
AudioReach status-query timeout (`1001021`) still appears; it did not prevent
sound-card registration or the tested playback/capture streams.

## DNF package feeds

The QLI image includes DNF/RPM and its package database, but no configured
repositories. A search of Qualcomm's public release artifacts and source
documentation on September 13, 2026 did not identify a compatible public QLI
2.0 RPM feed. The CodeLinaro `downloads/2.x` directory is a source mirror;
the reference-board download directory contains flashable ZIPs, not an RPM feed.

An ARM64 Fedora or CentOS repository is not a compatible replacement for this
Yocto userspace. For additional host utilities, build RPMs with the matching
QLI 2.0 locked Yocto configuration, then publish their package index. For
example, from that initialized build environment:

```sh
bitbake net-tools iproute2
bitbake package-index
```

Serve the resulting `tmp/deploy/rpm` directory with its metadata. On the target,
create `/etc/yum.repos.d/qli-extras.repo`. This is a template for a feed we would
operate; the URL and signing key below are placeholders, not an existing service:

```ini
[qli-extras]
name=Tachyon QLI 2.0 extra utilities
baseurl=https://YOUR-FEED-HOST/qli/2.0/rpm/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-tachyon-qli
includepkgs=net-tools net-tools-* iproute2-ss
```

Sign the RPMs, install the feed's verified public key, then run `dnf makecache`
and `dnf install net-tools`. This narrow feed does not require a full reflash.
The reference image's RPM database still lists its original kernel packages,
whereas the composer replaces the actual kernel/modules with Particle's 6.8
files. Do not use a general QLI kernel update or distro-wide DNF upgrade on
this hybrid image. Expand the extra-package allowlist with reviewed dependencies.

See the [Yocto runtime package management instructions](https://docs.yoctoproject.org/dev/dev-manual/packages.html#using-rpm)
and [QLI 2.0 locked build instructions](https://github.com/qualcomm-linux/meta-qcom-releases/tree/qli-2.0).

For generic utilities, [Entware](https://github.com/Entware/Entware/wiki) is
another candidate: it publishes an `aarch64-k3.10` feed, installs binaries and
their libraries under `/opt`, and uses `opkg`. This is a separate userspace
package environment, not a QLI DNF repository. Its architecture/kernel baseline
fits this board, but it has not been installed or tested here. Direct requests
to `bin.entware.net` timed out during the feed investigation.

## Acceptance

See [QLI-VALIDATION.md](QLI-VALIDATION.md) for dated results and checks that
remain pending. The list below describes acceptance criteria, not a claim
that every check has passed on the latest image.

- QLI `/etc/os-release`, kernel `6.8.0-1058-particle`, matching module tree.
- Writable root filesystem; `/vendor` and `/persist` mounted correctly.
- Serial root shell and USB ADB; SSH host keys generated and key login works.
- Wi-Fi association, DHCP, DNS and SSH over the lab network.
- One normal reboot and two cold boots with networking returning each time.
- No kernel faults, filesystem errors or missing firmware required for these checks.

Capture `uname -a`, `/proc/cmdline`, `findmnt`, `systemctl --failed`, `dmesg`,
`journalctl -b`, `nmcli device status` and the build JSON alongside the image
digest and Embroid operation records. Cellular and GPU follow-up checks are
described above, along with audio validation. Full Particle service integration
remains unfinished.

`make test_qli` exercises the flash bounds, protected partitions, checksum
coverage, tampered payloads and image symlink resolution. Each real build also
runs native QLI executable/linker checks, inspects the initramfs and DTB,
checks ext4 twice, and validates the manifest against the vendored Particle
schemas from `https://linux-dist.particle.io/schema/`.

## Particle stack integration (draft)

`versions.json` now owns the QLI pins. `QLI_VERSIONS_FILE` remains an override
and defaults to `VERSIONS_FILE`. Ubuntu builds retain their implementation and
can use a versions file from the Ubuntu branch explicitly; the QLI branch no
longer carries a second set of Ubuntu kernel/firmware/package pins.

`build_qli` requires the exact component RPM artifacts and their complete
additional dependency closure in `rpm_packages`. The checked-in list is empty
because the QLI SDK build has not run yet. This deliberately blocks composition:
there is no fallback to a partial image, Debian packages or an external feed.

1. On a Linux x86_64 host meeting Qualcomm's build requirements, run
   `scripts/qli/build-sdk.sh versions.json /path/to/yocto-workspace`.
2. Source the generated aarch64 SDK. Build each component with its
   `packaging/build-rpm.sh`; stage the pinned syscon inputs using its checksum
   verifier. Build the missing utilities with the locked Yocto configuration.
   Kigen's existing serial binary is wrapped by `scripts/qli/package-lpa.py`.
3. Verify native module loading and installed dependencies against the QLI
   rootfs. Pin successful outputs from `packages.json`, including source commit,
   version/release, aarch64/noarch architecture, QLI revision, URL and SHA-256.
4. Run `make build_qli INPUT_REGION=NA` and `INPUT_REGION=RoW`. The composer
   stages only locked RPMs, generates a private file repository, installs exact
   package identities with external repositories disabled, applies the pinned
   QLI overlays, verifies installed identities/loading and removes the repository.

The locally committed composer CI workflow builds the pinned Yocto utilities/SDK
and component RPMs first,
retains their source metadata, then passes only checksum-matching locked outputs
to both regional image jobs. Configure `QLI_SDK_RUNNER`, `QLI_YOCTO_WORKSPACE`
and the private-input read token `QLI_INPUTS_TOKEN`. The default hosted runner
fails the prerequisites rather than attempting a build without the required
space/toolchain. Component repositories also provide standalone SDK dispatch
jobs. GitHub rejected the workflow push because the credential lacks `workflow` scope.
That commit remains local; the pipeline needs its first configured-host run.
No package feed, release tag or release publication is part of this work.

See [PARTICLE-STACK-VALIDATION.md](PARTICLE-STACK-VALIDATION.md) for acceptance
status. Existing hardware results elsewhere in this document describe the older
bring-up image, not the new Particle stack.
