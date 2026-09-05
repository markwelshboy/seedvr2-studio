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

The build wrapper uses the dedicated `buildkit-scratch` Buildx builder by default, matching the other inference repositories.

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
├── tensorrt-onnx/              # portable, shared across GPU types
├── tensorrt-artifacts/
│   └── <gpu-name>/             # GPU/runtime-specific .rtxplan files
└── logs/
```

The image symlinks those paths into the upstream application at startup. Hugging Face and Torch caches are also rooted beneath `/workspace/.cache`.

## Portable ONNX artifacts

The fixed-shape TensorRT ONNX graphs are expensive to trace and the 21-frame encoder export exceeds a 48 GB-class GPU. A canonical set was generated on a 96 GB RTX PRO 6000 Blackwell and is stored in a private Hugging Face dataset.

By default the image uses:

```text
HF_ONNX_REPO=markwelshboyx/seedvr2-studio-onnx
HF_ONNX_REPO_TYPE=dataset
HF_ONNX_REVISION=main
HF_ONNX_ALLOW_EXPORT=false
HF_ONNX_ALLOW_MISMATCH=false
```

These values can be overridden in the RunPod template. Authentication is taken from the first available token variable:

```text
HF_ONNX_TOKEN
HF_TOKEN
HUGGING_FACE_HUB_TOKEN
```

Recommended RunPod template variables are therefore:

```text
HF_TOKEN=<private-repo read token>
HF_ONNX_REPO=markwelshboyx/seedvr2-studio-onnx
HF_ONNX_REPO_TYPE=dataset
HF_ONNX_REVISION=main
```

`prepare-tensorrt` downloads `SHA256SUMS`, verifies all four ONNX files byte-for-byte, checks `manifest.txt` against the upstream commit baked into the image, and stores the portable graphs under `/workspace/seedvr2-studio/tensorrt-onnx/`. Existing verified files are reused. The checksum parser accepts both basename entries and the absolute-path entries used by the first canonical upload.

If the configured private repo cannot be downloaded, checksum validation fails, or the manifest belongs to a different upstream revision, preparation stops rather than silently starting the high-memory local ONNX trace.

To intentionally regenerate missing ONNX files using upstream's exporter, explicitly set:

```text
HF_ONNX_ALLOW_EXPORT=true
```

To intentionally consume an ONNX set whose manifest does not match the image's pinned upstream revision, explicitly set:

```text
HF_ONNX_ALLOW_MISMATCH=true
```

The mismatch override should only be used when compatibility is known. Setting `HF_ONNX_REPO` to an empty value disables the remote source, but local export still requires `HF_ONNX_ALLOW_EXPORT=true`.

## TensorRT preparation

ONNX graphs are portable; TensorRT RTX plans are GPU/runtime-specific. Once the pod is running on its final GPU, run:

```bash
prepare-tensorrt
```

The command:

1. fetches and verifies the four portable ONNX artifacts from the configured Hugging Face repo;
2. validates the ONNX manifest against the image's pinned upstream revision;
3. links those portable graphs into the current GPU's artifact directory;
4. downloads/validates the default SeedVR2 model and VAE;
5. invokes upstream TensorRT preparation, which sees the ONNX graphs already present and therefore skips tracing;
6. builds only missing `.rtxplan` files for the current GPU/runtime.

Plans are persisted beneath:

```text
/workspace/seedvr2-studio/tensorrt-artifacts/<gpu-name>/
```

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
