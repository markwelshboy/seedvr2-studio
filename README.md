# seedvr2-studio

RunPod/Linux packaging for [VRGDG-SeedVR2-TensorRT-Studio](https://github.com/vrgamegirl19/VRGDG-SeedVR2-TensorRT-Studio).

This repository is intentionally a thin container/runtime wrapper rather than a fork of the upstream application. The Docker build clones a pinned upstream revision, applies the minimal Linux compatibility patch, installs the upstream-tested CUDA 13 stack, and adds RunPod/browser plumbing.

## Targets

- `final` — SeedVR Studio FastAPI/JavaScript UI directly on port `7870`.
- `browser` — `final` plus Xvfb, Openbox, Google Chrome, x11vnc and noVNC. This gives the browser a pod-local filesystem view similar to the browser target in `comfyui-inference-headless-to-desktop`.

The browser target exposes:

- `8988` — noVNC / in-pod Chrome
- `7870` — direct SeedVR Studio UI/API
- `5090` — raw VNC
- `22` — SSH recovery access

## Build

The build wrapper follows the same `docker buildx` flow as the other inference repositories.

```bash
bash ./build_seedvr2-studio.sh --target browser
```

The default action pushes to Docker Hub:

```text
markwelshboy/seedvr2-studio:latest
```

A browser-target build uses the same repository name when built alone. To produce separately named headless and browser images in one invocation:

```bash
bash ./build_seedvr2-studio.sh --all-targets
```

which builds/pushes:

```text
markwelshboy/seedvr2-studio:latest
markwelshboy/seedvr2-studio-browser:latest
```

Useful development builds:

```bash
# Build the browser image and load it into local Docker.
bash ./build_seedvr2-studio.sh --target browser --load

# Follow current upstream main rather than the pinned tested revision.
bash ./build_seedvr2-studio.sh \
  --target browser \
  --build-arg UPSTREAM_REF=main
```

## Persistent RunPod data

Mutable state is placed beneath:

```text
/workspace/seedvr2-studio/
├── models/SEEDVR2/
├── outputs/
├── tensorrt-artifacts/
│   └── <gpu-name>/
└── logs/
```

The image symlinks those paths into the upstream application at startup. Hugging Face and Torch caches are also rooted beneath `/workspace/.cache`.

## TensorRT preparation

TensorRT RTX plans are GPU-specific, so they are **not** built into the Docker image. Once the pod is running on its final GPU, run:

```bash
prepare-tensorrt
```

That downloads/validates the upstream default model and VAE, then builds the four upstream TensorRT VAE profiles into a persistent GPU-name-specific directory beneath `tensorrt-artifacts/`.

To inspect the CUDA/PyTorch/SageAttention/TensorRT stack:

```bash
verify-studio
```

## Upstream baseline

The initial image pins upstream commit:

```text
f3ab8f65c8a630cd4052b3c5802ea056a5899631
```

The baseline follows upstream's tested Windows CUDA 13 environment where practical:

- Python 3.12
- PyTorch `2.15.0.dev20260824+cu130` with fallback to the current compatible cu130 nightly
- torchvision `0.30.0.dev20260824+cu130`
- torchaudio `2.11.0.dev20260824+cu130`
- SageAttention `1.0.6`
- TensorRT RTX `1.6.1.120`
- ONNX `1.22.0`
- ONNXScript `0.7.1`
- Polygraphy `0.53.4`

The Windows-only `triton-windows` package is omitted; the Linux PyTorch stack supplies Triton.
