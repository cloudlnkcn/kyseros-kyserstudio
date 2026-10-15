# ============================================================
# Kyserai GPU app images for KyserOS: nvidia / amd / intel.
#
# The app program is Kyserai itself, built from the sibling
# kyserai checkout supplied as the named build context
# "kyserai" (never this repository):
#
#   docker buildx build \
#       --build-context kyserai=../kyserai \
#       --build-arg GPU_VARIANT=nvidia \
#       -t kyserai:nvidia .
#
# ============================================================
# syntax=docker/dockerfile:1

ARG UBUNTU_VERSION=24.04

# ------------------------------------------------------------
# 1. Build stage: compile the Kyserai C++ server and web app
# ------------------------------------------------------------
FROM ubuntu:${UBUNTU_VERSION} AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    ninja-build \
    libssl-dev \
    pkg-config \
    libdrm-dev \
    libgtk-3-dev \
    git \
    nodejs \
    npm \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=kyserai . /app

RUN rm -rf build \
    && cmake --preset default \
    && cmake --build --preset default web-app

# ------------------------------------------------------------
# 2. Runtime stage: lean image, GPU stacks stay on the host
#    (KyserOS publishes CDI for the matched accelerator).
#    llama.cpp / sd.cpp / FLM backends are downloaded at
#    runtime by Kyserai itself, so no GPU toolkit is baked in.
# ------------------------------------------------------------
FROM ubuntu:${UBUNTU_VERSION}

ARG GPU_VARIANT=nvidia

ENV DEBIAN_FRONTEND=noninteractive

# Common runtime libraries for kyseraid plus the Vulkan loader
# (used by the vulkan and SYCL llama.cpp backends).
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libcurl4 \
    curl \
    libssl3 \
    zlib1g \
    libdrm2 \
    libvulkan1 \
    vulkan-tools \
    libgomp1 \
    libatomic1 \
    unzip \
    jq \
    && rm -rf /var/lib/apt/lists/*

# AMD only: XRT user space for the FastFlowLM NPU backend.
# FLM itself auto-installs on demand at runtime.
RUN if [ "$GPU_VARIANT" = "amd" ]; then \
        apt-get update && apt-get install -y --no-install-recommends \
            software-properties-common \
        && add-apt-repository -y ppa:amd-team/xrt \
        && apt-get update && apt-get install -y --no-install-recommends \
            libxrt2 \
            libxrt-npu2 \
        && rm -rf /var/lib/apt/lists/*; \
    fi

WORKDIR /opt/kyserai

# Private runtime directory so kyseraid can use get_runtime_dir()
RUN mkdir -p /run/kyserai && chmod 700 /run/kyserai
ENV XDG_RUNTIME_DIR=/run/kyserai

# Service-style state layout, matching the deb deployment where the
# systemd unit runs with HOME=/var/lib/kyserai (StateDirectory). Pointing
# HOME there also keeps FLM's ~/.flm/models inside the data volume.
# Pin the cache root explicitly so the mount is deterministic
# (config.json, downloaded models and backend binaries).
RUN mkdir -p /var/lib/kyserai
ENV HOME=/var/lib/kyserai
ENV KYSERAI_CACHE_DIR=/var/lib/kyserai

COPY --from=builder /app/build/kyseraid ./kyseraid
COPY --from=builder /app/build/kyserai ./kyserai
COPY --from=builder /app/build/resources ./resources

RUN chmod +x ./kyseraid ./kyserai

EXPOSE 13305

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:13305/live || exit 1

CMD ["./kyseraid", "--host", "0.0.0.0"]
