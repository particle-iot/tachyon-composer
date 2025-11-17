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
