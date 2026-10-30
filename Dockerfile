# ============================================================
# Kyserai app image for KyserOS: one image for every GPU
# provider variant.
#
# The app program is Kyserai itself, built from the sibling
# kyserai checkout supplied as the named build context
# "kyserai" (never this repository):
#
#   docker buildx build \
#       --build-context kyserai=../kyserai \
#       -t kyserai:v10.26.3-kyseros.1 .
#
# Per the KyserOS provider contract (kyseros-nvidia, kyseros-amd,
# kyseros-intel), the image ships no GPU driver stack: kernel
# modules, firmware, and driver user space (CUDA, ROCm, XRT, the
# Vulkan ICDs) come from the OS host provider that the variant
# manifest's CDI request selects, injected when the container
# starts. The image only carries the Vulkan loader, which the
# contract makes the app's own responsibility, plus Kyserai's
# common runtime libraries.
# ============================================================
# syntax=docker/dockerfile:1

ARG UBUNTU_VERSION=24.04

# GitHub mirror prefix for the Khronos clones below. Defaults to the
# ghfast.top proxy for networks that cannot reach github.com directly;
# pass an empty value to use the upstream URLs.
ARG GITHUB_MIRROR=https://ghfast.top/

# Ubuntu archive mirror host, used by every stage below. Defaults to
# the Aliyun mirror; pass another host (or the upstream
# archive.ubuntu.com) to override.
ARG APT_MIRROR=mirrors.aliyun.com

# Pinned Khronos Vulkan release built for every variant (Ubuntu
# 24.04 ships an older 1.3.x loader in its distro packages).
ARG VULKAN_VERSION=1.4.366

# ------------------------------------------------------------
# 1. Build stage: compile the Kyserai C++ server and web app
# ------------------------------------------------------------
FROM ubuntu:${UBUNTU_VERSION} AS builder

ARG APT_MIRROR

ENV DEBIAN_FRONTEND=noninteractive

RUN sed -i "s|archive.ubuntu.com|$APT_MIRROR|g; s|security.ubuntu.com|$APT_MIRROR|g" \
        /etc/apt/sources.list.d/ubuntu.sources

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

# kyserai's CMake FetchContent pins third-party sources (mbedTLS for
# download digest verification) on github.com, which this build network
# cannot reach directly. Rewrite every github.com git URL through the
# GITHUB_MIRROR prefix, like the Khronos clones in the stage below; an
# empty mirror value rewrites to the upstream URL unchanged.
ARG GITHUB_MIRROR
RUN git config --global \
        url."${GITHUB_MIRROR}https://github.com/".insteadOf \
        https://github.com/

WORKDIR /app

COPY --from=kyserai . /app

RUN rm -rf build \
    && cmake --preset default \
    && cmake --build --preset default web-app

# ------------------------------------------------------------
# 2. Vulkan loader stage: build the current Khronos loader
#    release (VULKAN_VERSION) so all variants get the latest
#    loader instead of Ubuntu's distro package
# ------------------------------------------------------------
FROM ubuntu:${UBUNTU_VERSION} AS vulkan-loader

ARG VULKAN_VERSION
ARG GITHUB_MIRROR
ARG APT_MIRROR

ENV DEBIAN_FRONTEND=noninteractive

RUN sed -i "s|archive.ubuntu.com|$APT_MIRROR|g; s|security.ubuntu.com|$APT_MIRROR|g" \
        /etc/apt/sources.list.d/ubuntu.sources

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    ninja-build \
    git \
    pkg-config \
    ca-certificates \
    libx11-xcb-dev \
    libxkbcommon-dev \
    libwayland-dev \
    libxrandr-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch v${VULKAN_VERSION} \
        ${GITHUB_MIRROR}https://github.com/KhronosGroup/Vulkan-Headers.git \
    && cmake -S Vulkan-Headers -B Vulkan-Headers/build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/opt/vulkan \
    && cmake --install Vulkan-Headers/build

RUN git clone --depth 1 --branch v${VULKAN_VERSION} \
        ${GITHUB_MIRROR}https://github.com/KhronosGroup/Vulkan-Loader.git \
    && cmake -S Vulkan-Loader -B Vulkan-Loader/build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_TESTS=OFF \
        -DVULKAN_HEADERS_INSTALL_DIR=/opt/vulkan \
        -DCMAKE_INSTALL_PREFIX=/opt/vulkan \
    && cmake --build Vulkan-Loader/build --target vulkan \
    && cmake --install Vulkan-Loader/build

# ------------------------------------------------------------
# 3. Runtime stage: lean image, the GPU stack stays on the
#    host (KyserOS publishes CDI for the matched provider).
#    llama.cpp / sd.cpp / FLM backends - including the CUDA and
#    ROCm runtimes they need - are downloaded at runtime by
#    Kyserai itself, so nothing driver-shaped is baked in.
# ------------------------------------------------------------
FROM ubuntu:${UBUNTU_VERSION}

ARG APT_MIRROR

ENV DEBIAN_FRONTEND=noninteractive

RUN sed -i "s|archive.ubuntu.com|$APT_MIRROR|g; s|security.ubuntu.com|$APT_MIRROR|g" \
        /etc/apt/sources.list.d/ubuntu.sources

# Common runtime libraries for kyseraid plus the distro Vulkan
# loader and tools. The loader is shared by every variant and
# feeds the Vulkan and SYCL llama.cpp backends. The PNG/JPEG/WebP
# and audio libraries are the media runtime that app backends
# (for example the bundled gufo engine) link directly; ffmpeg and
# ffprobe are invoked as separate executables for media output.
# xz-utils: backend release archives are .tar.xz and Kyserai extracts
# them by invoking the system tar, which shells out to xz — without
# it every backend install dies on "tar: xz: Cannot exec".
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
    libicu74 \
    libpng16-16 \
    libjpeg-turbo8 \
    libwebp7 \
    libsndfile1 \
    libsoxr0 \
    ffmpeg \
    unzip \
    jq \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Override the distro libvulkan1 with the current Khronos loader;
# /usr/local/lib wins the ldconfig cache over the distro path.
COPY --from=vulkan-loader /opt/vulkan/lib/libvulkan.so.1* /usr/local/lib/
RUN ldconfig

# The matched provider's CDI spec supplies the GPU device nodes
# and its driver user space (ICDs, libdrm, libcuda, RADV) at
# container start; XRT for the XDNA2 NPU is likewise the AMD
# provider's responsibility, not an image ingredient.

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

# 13305 is the plain HTTP listener; kyseraid's default TLS config
# (tls.enabled) also serves HTTPS on 13306.
EXPOSE 13305 13306

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:13305/live || exit 1

# KyserOS terminates authenticated LAN HTTPS and routes to this port,
# so Kyserai's UDP beacon would only ever broadcast the container's
# bridge IP to the bridge subnet; discovery is the platform's job.
CMD ["./kyseraid", "--host", "0.0.0.0", "--no-broadcast"]
