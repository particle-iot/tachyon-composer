ARG BUILDER_IMAGE=tachyon-system-image-builder:1.4
FROM ${BUILDER_IMAGE}
USER root
# Build tools and headers only; nothing is apt-installed into QLI.
RUN apt-get update && apt-get install -y --no-install-recommends liblzma-dev python3-jsonschema rpm createrepo-c \
    meson ninja-build libglib2.0-dev libudev-dev libdbus-1-dev libndp-dev \
    libsystemd-dev libmm-glib-dev uuid-dev libnss3-dev libpolkit-gobject-1-dev chrpath \
    && rm -rf /var/lib/apt/lists/*
