#!/usr/bin/env bash
set -euo pipefail
STUDIO_ROOT="${STUDIO_ROOT:-/opt/seedvr-studio}"
STUDIO_DATA="${STUDIO_DATA:-/workspace/seedvr2-studio}"
mkdir -p "${STUDIO_DATA}/logs"
cd "${STUDIO_ROOT}"

echo "GPU:"
nvidia-smi --query-gpu=name,uuid,driver_version --format=csv,noheader || true

TOTAL_MIB="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d ' ' || true)"
if [[ "${TOTAL_MIB}" =~ ^[0-9]+$ ]] && (( TOTAL_MIB < 60000 )); then
  echo ""
  echo "[warn] This GPU has ${TOTAL_MIB} MiB VRAM."
  echo "[warn] The upstream 21-frame 512x512 encoder ONNX export has been observed"
  echo "[warn] to require more than a 48 GB-class GPU during CUDA tracing."
  echo "[warn] Upstream will fall back to CPU export on CUDA OOM; this is valid but slow."
  echo "[warn] For GPU-only ONNX preparation, an 80 GB-class GPU is recommended."
  echo ""
fi

echo "Downloading/validating the default SeedVR2 model and VAE..."
python scripts/download_models.py 2>&1 | tee "${STUDIO_DATA}/logs/model-prepare.log"

echo "Building GPU-specific TensorRT RTX VAE engines..."
python scripts/prepare_tensorrt.py 2>&1 | tee "${STUDIO_DATA}/logs/tensorrt-prepare.log"

echo "TensorRT preparation complete."
