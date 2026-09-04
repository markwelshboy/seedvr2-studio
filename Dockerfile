# syntax=docker/dockerfile:1.7

ARG CUDA_IMAGE=nvidia/cuda:13.0.2-devel-ubuntu24.04
FROM ${CUDA_IMAGE} AS runtime-base

ARG BUILD_DATE=""
ARG VCS_REF="unknown"
ARG IMAGE_VERSION="0.1.0"
ARG UPSTREAM_REPO="https://github.com/vrgamegirl19/VRGDG-SeedVR2-TensorRT-Studio.git"
ARG UPSTREAM_REF="f3ab8f65c8a630cd4052b3c5802ea056a5899631"
ARG TORCH_INDEX="https://download.pytorch.org/whl/nightly/cu130"
ARG TORCH_VER="2.15.0.dev20260824+cu130"
ARG TORCHVISION_VER="0.30.0.dev20260824+cu130"
ARG TORCHAUDIO_VER="2.11.0.dev20260824+cu130"
ARG SAGEATTENTION_VER="1.0.6"
ARG TENSORRT_RTX_VER="1.6.1.120"

LABEL org.opencontainers.image.title="seedvr2-studio" \
      org.opencontainers.image.description="RunPod/Linux packaging for VRGDG SeedVR2 TensorRT Studio" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.source="https://github.com/markwelshboy/seedvr2-studio"

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONUTF8=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_INPUT=1 \
    PIP_PREFER_BINARY=1 \
    VENV=/opt/venv \
    STUDIO_ROOT=/opt/seedvr-studio \
    STUDIO_DATA=/workspace/seedvr2-studio \
    HF_HOME=/workspace/.cache/huggingface \
    TORCH_HOME=/workspace/.cache/torch \
    XDG_CACHE_HOME=/workspace/.cache

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      python3.12 python3.12-venv python3.12-dev \
      git git-lfs curl ca-certificates jq \
      build-essential gcc g++ cmake ninja-build pkg-config \
      ffmpeg aria2 rsync tmux unzip wget vim less nano \
      libgl1 libglib2.0-0 \
      openssh-server iproute2 procps \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd /workspace \
    && git lfs install --system \
    && python3.12 -m venv "${VENV}"

ENV PATH="${VENV}/bin:${PATH}"

RUN --mount=type=cache,target=/root/.cache/pip \
    python -m pip install -U pip setuptools wheel

# Match the exact CUDA 13 nightly tested by upstream. If PyTorch has pruned
# that nightly from the index, fall back to the current mutually-compatible
# cu130 nightlies, matching the behavior of upstream's Windows installer.
RUN --mount=type=cache,target=/root/.cache/pip \
    if ! python -m pip install --pre \
        "torch==${TORCH_VER}" \
        "torchvision==${TORCHVISION_VER}" \
        "torchaudio==${TORCHAUDIO_VER}" \
        --index-url "${TORCH_INDEX}"; then \
      echo "Exact tested PyTorch nightly unavailable; falling back to latest cu130 nightly"; \
      python -m pip install --pre torch torchvision torchaudio --index-url "${TORCH_INDEX}"; \
    fi

RUN git clone "${UPSTREAM_REPO}" "${STUDIO_ROOT}" \
    && git -C "${STUDIO_ROOT}" checkout "${UPSTREAM_REF}" \
    && git -C "${STUDIO_ROOT}" submodule update --init --recursive

WORKDIR ${STUDIO_ROOT}

COPY src/patch-upstream-linux.py /tmp/patch-upstream-linux.py
RUN python /tmp/patch-upstream-linux.py "${STUDIO_ROOT}" \
    && rm -f /tmp/patch-upstream-linux.py

# Install Studio + vendored SeedVR2 requirements. Torch is already present and
# satisfies the unpinned torch entries in the vendored requirements file.
RUN --mount=type=cache,target=/root/.cache/pip \
    python -m pip install --editable . --index-url https://pypi.org/simple \
    && python -m pip install --requirement vendor/seedvr2/requirements.txt --index-url https://pypi.org/simple

# Linux equivalent of requirements-windows-cu130.txt. PyTorch's Linux wheel
# provides Triton; only the Windows-specific triton-windows package is omitted.
RUN --mount=type=cache,target=/root/.cache/pip \
    python -m pip install --no-build-isolation \
      "sageattention==${SAGEATTENTION_VER}" \
      "tensorrt-rtx==${TENSORRT_RTX_VER}" \
      "onnx==1.22.0" \
      "onnxscript==0.7.1" \
      "polygraphy==0.53.4" \
      --index-url https://pypi.org/simple

COPY src/start_script.sh /start_script.sh
COPY src/prepare-tensorrt.sh /usr/local/bin/prepare-tensorrt
COPY src/verify-studio.sh /usr/local/bin/verify-studio
RUN chmod +x /start_script.sh /usr/local/bin/prepare-tensorrt /usr/local/bin/verify-studio

# Direct web/API target.
FROM runtime-base AS final
ENV ENABLE_BROWSER=false \
    STUDIO_HOST=0.0.0.0 \
    STUDIO_PORT=7870
EXPOSE 22 7870
ENTRYPOINT ["/start_script.sh"]

# Browser/noVNC target: same plumbing as comfyui-inference-headless-to-desktop.
FROM runtime-base AS browser

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
      xvfb x11vnc novnc websockify dbus-x11 xauth \
      mesa-utils libgl1-mesa-dri openbox wget gnupg \
    && install -d -m 0755 /etc/apt/keyrings \
    && wget -qO- https://dl.google.com/linux/linux_signing_key.pub \
       | gpg --batch --yes --no-tty --dearmor -o /etc/apt/keyrings/google-chrome.gpg \
    && chmod a+r /etc/apt/keyrings/google-chrome.gpg \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
       > /etc/apt/sources.list.d/google-chrome.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends google-chrome-stable \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY src/start-local-browser.sh /usr/local/bin/start-local-browser
COPY src/stop-local-browser.sh /usr/local/bin/stop-local-browser
RUN chmod +x /usr/local/bin/start-local-browser /usr/local/bin/stop-local-browser

ENV ENABLE_BROWSER=true \
    STUDIO_HOST=0.0.0.0 \
    STUDIO_PORT=7870 \
    START_URL=http://127.0.0.1:7870/ \
    NOVNC_PORT=8988 \
    VNC_PORT=5090
EXPOSE 22 7870 8988 5090
ENTRYPOINT ["/start_script.sh"]
