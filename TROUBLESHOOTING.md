# Troubleshooting Guide

## "Exec format error" when running chroot commands

### Symptoms
```
chroot: failed to run command '/usr/bin/env': Exec format error
```

### Root Cause
This error occurs when the Docker host architecture doesn't match the target rootfs architecture:
- **Host**: x86_64 (amd64)
- **Target rootfs**: ARM64 (aarch64)

The x86_64 kernel cannot directly execute ARM64 binaries without emulation support.

### Solution

**The build system automatically detects and configures QEMU** when needed. Simply run your build command:

```bash
make build_24.04 VERSIONS_FILE=./versions.json INPUT_REGION=RoW INPUT_VARIANT=headless
```

The build will:
1. Detect x86_64 architecture
2. Check for QEMU registration
3. Automatically run: `docker run --rm --privileged multiarch/qemu-user-static --reset -p yes`
4. Proceed with the build

#### Manual Setup (if automatic fails)

If automatic setup fails, you can manually enable QEMU:

**Option 1: Using Make**
```bash
make setup_qemu
```

**Option 2: Using Docker directly**
```bash
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
```

**Option 3: Install qemu-user-static on host**
```bash
sudo apt-get update
sudo apt-get install -y qemu-user-static binfmt-support
```

### Verification

The build automatically verifies QEMU is working. You can also manually check:

```bash
# Check if QEMU is configured
make check_qemu

# Or verify binfmt_misc directly
ls -la /proc/sys/fs/binfmt_misc/ | grep qemu-aarch64
```

If you see `qemu-aarch64` listed, ARM64 emulation is working.

### Why This Works

The Dockerfile already includes `qemu-user-static` (line 22):
```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
    ...
    qemu-user-static \
    ...
```

However, QEMU user-mode emulation requires **kernel-level binfmt_misc registration** to work transparently in `chroot` environments. Installing `qemu-user-static` in the container alone is not sufficient - the **host kernel** needs to be configured to recognize and handle ARM64 binaries.

### Alternative: Build on ARM64 host

For best performance and to avoid emulation overhead, run builds on an ARM64 host:
- AWS Graviton instances (t4g, c7g, etc.)
- GitHub Actions with `ubuntu-latest-arm64` runner
- Cloud providers with ARM64 VMs

### Platform-Specific Notes

#### GitHub Actions
The repository's CI runs on `ubuntu-tachyon` runner, which should be ARM64 or have QEMU properly configured.

#### Docker Desktop (macOS/Windows)
Docker Desktop automatically handles architecture emulation. This error typically doesn't occur on these platforms.

#### Linux (x86_64)
Most likely to encounter this issue. Follow Solution Option 1 above.

## Shipped image is `e2fsck`-clean but missing its most recent overlay writes

### Symptoms

On the device, `/etc/particle/distro_versions.json` is not JSON — it holds the
control data of whichever `.deb` was being unpacked around the same time:

```
$ jq -r '.distro.board' /etc/particle/distro_versions.json
jq: parse error: Invalid numeric literal at line 1, column 8
$ head -2 /etc/particle/distro_versions.json
Package: v4l-utils
Version: 1.26.1-4build3
```

Everything that reads it then fails. `particle-tachyon-syscon.sh` resolves the
board from that file, so the MCU upgrade service dies with:

```
Unknown board:
$ systemctl show -p Result --value particle-tachyon-syscon.service
exit-code
```

dpkg is broken in the same image, because its transaction never completed:

```
$ dpkg --audit
dpkg: error: parsing file '/var/lib/dpkg/updates/0001' near line 5:
 missing 'Package' field
$ apt-get install -y anything
E: dpkg was interrupted, you must manually run 'dpkg --configure -a' to correct the problem.
```

Alongside that: leftover `*.dpkg-new` files whose packages `dpkg/status` claims
are `install ok installed`, and a non-empty `/var/lib/dpkg/updates/`.

The image passes `e2fsck -fn` with exit 0 and reports "clean", which is what
makes this so easy to misdiagnose as filesystem corruption. It is not.

### Root Cause

The overlay tool persisted the rootfs **while it was still mounted**. Its teardown
both silenced and ignored every `umount` failure:

```sh
sudo umount "$MOUNT_POINT/sys" 2>/dev/null || true    # failure invisible AND ignored
...
sudo dd if="${PART_ROOT}" of="$raw_ext4" ...          # copies a live filesystem
```

When a `umount` failed, the `dd` (or re-sparsify) ran against a mounted,
dirty filesystem. ext4 commits its journal roughly every 5 seconds, so the copy
contains a **journal-consistent but stale** filesystem: it replays cleanly under
`e2fsck` while the newest page-cache writes — the tail end of the overlay, which
is exactly where `add-particle-version` and the last package unpacks live — are
simply absent.

That single bug accounts for all three symptoms above. There is no separate dpkg
bug and no filesystem corruption.

### Solution

Fixed upstream in `tachyon-overlay-tool`:

- Never persist a filesystem that is still mounted — a failed teardown now aborts
  the build loudly instead of shipping a plausible-looking image.
- Tear the chroot down before unmounting: kill processes whose root or cwd is
  inside the mount, enumerate submounts deepest-first, and report what is holding
  a mount when it will not release.

And in this repo, `compose_24_04.sh` gained a `content_gate()` that runs after the
image is persisted, so a regression cannot ship silently even if teardown breaks
again. It rejects the image on any of: leftover `*.dpkg-new`/`*.dpkg-tmp`, a
non-empty `/var/lib/dpkg/updates/`, or a `distro_versions.json` that is not JSON
with the expected keys.

### Verification

An `e2fsck` pass is not sufficient — check content:

```bash
sudo mount -o ro,loop rootfs.ext4 /mnt/img
find /mnt/img -xdev \( -name '*.dpkg-new' -o -name '*.dpkg-tmp' \)   # expect nothing
ls -1 /mnt/img/var/lib/dpkg/updates/                                  # expect empty
jq -e '.distro.board' /mnt/img/etc/particle/distro_versions.json      # expect a board
sudo umount /mnt/img
```

Note the failure was variant-dependent in practice: headless builds tripped it
while desktop builds did not, so a green desktop image is not evidence that a
headless image from the same run is good. Check the variant you actually ship.

## Board hangs in XBL at `LP4 DDR detected` after a manual flash

```
B -   1054995 - sbl1_ddr_init, Start
B -   1058380 - LP4 DDR detected
```

XBL came up off LUN 1, finished DDR init, and found nothing to hand off to. It is not a DDR
fault and not a bad image.

The firmware set — `uefi`, `tz`, `hyp`, `aop`, `devcfg`, `dtb`, `core_nhlos`, the whole boot
chain after XBL — moved from LUN 4 to **LUN 6** in #68 and first shipped in **1.2.6**. A
hand-written qdl invocation that programs `rawprogram0` through `rawprogram5` leaves LUN 6
empty. There are seven.

Fix: reflash with the manifest-driven form, which cannot miss a LUN.

```bash
particle flash --tachyon <zip-or-directory>
```

See [`FLASHING.md`](FLASHING.md).

## `failed to setup programming` immediately after the GPTs

```
flashed "BackupGPT" successfully
[ERROR] failed to setup programming
[ERROR] firehose_run failed
```

Firehose cannot open a LUN the image wants to program, because that LUN no longer exists on
the device. Almost always this means `provision_ufs22.xml` was applied — the copy shipped in
1.2.0 through 1.2.19 carried `bLUEnable="0"` on LUN 6, and from 1.2.6 that is where the whole
firmware set lives.

Two things follow. The layout is repaired by `particle flash --tachyon <zip>`. The modem's
identity probably is not: that descriptor differs from real hardware on **all six** LUNs, so
applying it moves every boundary from LUN 1 upward — including **LUN 5**, which holds `fsg`,
`fsc`, `modemst1/2` and `nvdata1/2`. Check with `particle-tachyon-ril-ctl info` — a genuine
Tachyon reports `imei-1` beginning `86513606`. Recovery needs a `particle tachyon backup`
taken beforehand.

The descriptor is fixed on `main` and `scripts/assemble/validate_provisioning.py` now gates it
at build time. That makes the shipped file describe the device correctly; it does not make
re-provisioning a working board a thing anyone needs to do. See [`FLASHING.md`](FLASHING.md).
