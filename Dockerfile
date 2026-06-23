# syntax=docker/dockerfile:1.7
# particle-dockerfile-version=1.4
# this is the Dockerfile version.
# Update this ARG to change the base image and recompile it!

ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}

# Avoid interactive prompts during apt installs
ENV DEBIAN_FRONTEND=noninteractive

# Core deps. New-BP flow notes:
#  - mtools (mmd/mcopy/mdir): build the FAT efi.img and dtb.img
#    (nonhlos.img is shipped pre-built by the bp-fw artifact, not built here)
#  - dosfstools (mkfs.vfat), e2fsprogs (mkfs.ext4), util-linux (losetup/sfdisk/partx, in base)
#  - dpkg (dpkg-deb, in base): extract qcm6490-tachyon.dtb from the kernel deb
#  - libxml2-utils (xmllint), jq, xz-utils, rsync, zip/unzip
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    make \
    sudo \
    curl \
    wget \
    zip \
    unzip \
    qemu-user-static \
    qemu-utils \
    e2fsprogs \
    dosfstools \
    mtools \
    android-sdk-libsparse-utils \
    build-essential \
    device-tree-compiler \
    file \
    git \
    jq \
    xz-utils \
    libxml2-utils \
    rsync \
    git-lfs \
    livecd-rootfs \
    flex \
    bison \
    xxd \
    libssl-dev \
    libgnutls28-dev \
 && rm -rf /var/lib/apt/lists/*

# (No extra pip tools needed: the new-BP dtb step extracts qcm6490-tachyon.dtb with
# dpkg-deb, not the old extract-dtb package. Ubuntu 24.04 is PEP-668 externally-managed,
# so any future pip install here must pass --break-system-packages or use a venv.)

# The vendored sectoolsv2 signer (scripts/signing/sectools) is a PyInstaller bundle that
# dlopen()s libcrypt.so.2; Ubuntu 24.04 ships only libcrypt.so.1. Symlink it so the
# signer runs (needed for SIGNING_PROFILE=test|prod; harmless for profile=none).
RUN set -e; L="$(find / -name libcrypt.so.1 2>/dev/null | head -1)"; \
    [ -n "$L" ] && ln -sf "$L" "$(dirname "$L")/libcrypt.so.2" || true

# Ensure per-user pip installs are on PATH for the builder user
ENV PATH="/home/builder/.local/bin:${PATH}"

# Build-args to match host user (optional)
ARG UID=1000
ARG GID=1000

# Create 'builder' user with sudo (no password) and correct uid/gid
RUN if ! getent group "${GID}" >/dev/null; then groupadd -g "${GID}" builder; fi && \
    useradd -m -u "${UID}" -g "${GID}" builder && \
    usermod -aG sudo builder &&   \
    echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder && \
    chmod 0440 /etc/sudoers.d/builder

# Work in /project
WORKDIR /project

# Copy project files and give ownership to builder in one layer
COPY --chown=${UID}:${GID} . .

# Drop to the non-root user by default
USER builder

# Add GitHub to known_hosts for builder user
RUN mkdir -p ~/.ssh && \
    chmod 700 ~/.ssh && \
    ssh-keyscan -t rsa,ecdsa,ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null && \
    chmod 600 ~/.ssh/known_hosts

CMD ["bash"]