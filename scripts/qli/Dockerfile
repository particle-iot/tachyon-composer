ARG BUILDER_IMAGE=tachyon-system-image-builder:1.4
FROM ${BUILDER_IMAGE}
USER root
# Only build-time headers/static library; nothing is apt-installed into QLI.
RUN apt-get update && apt-get install -y --no-install-recommends liblzma-dev python3-jsonschema \
    && rm -rf /var/lib/apt/lists/*
