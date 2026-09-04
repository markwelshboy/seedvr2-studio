#!/usr/bin/env bash
set -euo pipefail
STUDIO_ROOT="${STUDIO_ROOT:-/opt/seedvr-studio}"
STUDIO_DATA="${STUDIO_DATA:-/workspace/seedvr2-studio}"
mkdir -p "${STUDIO_DATA}/logs"
cd "${STUDIO_ROOT}"

echo "GPU:"
nvidia-smi --query-gpu=name,uuid,driver_version --format=csv,noheader || true

echo "Downloading/validating the default SeedVR2 model and VAE..."
python scripts/download_models.py 2>&1 | tee "${STUDIO_DATA}/logs/model-prepare.log"

echo "Building GPU-specific TensorRT RTX VAE engines..."
python scripts/prepare_tensorrt.py 2>&1 | tee "${STUDIO_DATA}/logs/tensorrt-prepare.log"

echo "TensorRT preparation complete."
