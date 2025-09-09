# syntax=docker/dockerfile:1.7
# particle-dockerfile-version=1.0
# this is the Dockerfile version.
# Update this ARG to change the base image and recompile it!

ARG BASE_IMAGE=ubuntu:22.04
FROM ${BASE_IMAGE}

# Avoid interactive prompts during apt installs
ENV DEBIAN_FRONTEND=noninteractive

# Core deps (includes xmllint, mkfs.vfat, rsync via libxml2-utils, dosfstools, rsync)
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
    android-sdk-libsparse-utils \
    build-essential \
    device-tree-compiler \
    file \
    git \
    jq \
    xz-utils \
    libxml2-utils \
    dosfstools \
    rsync \
    git-lfs \
    livecd-rootfs \
 && rm -rf /var/lib/apt/lists/*

# Python tools
# (This provides extract-dtb; name left as-is from your comment)
RUN pip3 install --no-cache-dir extract-dtb

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