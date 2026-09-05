#!/usr/bin/env bash
set -euo pipefail

STUDIO_ROOT="${STUDIO_ROOT:-/opt/seedvr-studio}"
STUDIO_DATA="${STUDIO_DATA:-/workspace/seedvr2-studio}"
ONNX_DATA="${ONNX_DATA:-${STUDIO_DATA}/tensorrt-onnx}"
HF_ONNX_REPO="${HF_ONNX_REPO:-markwelshboyx/seedvr2-studio-onnx}"
HF_ONNX_REPO_TYPE="${HF_ONNX_REPO_TYPE:-dataset}"
HF_ONNX_REVISION="${HF_ONNX_REVISION:-main}"
HF_ONNX_ALLOW_EXPORT="${HF_ONNX_ALLOW_EXPORT:-false}"

truthy() {
  case "${1,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || true)"
GPU_KEY="$(printf '%s' "${GPU_NAME:-unknown-gpu}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+|-+$//g')"
GPU_KEY="${GPU_KEY:-unknown-gpu}"
TRT_DATA="${TRT_DATA:-${STUDIO_DATA}/tensorrt-artifacts/${GPU_KEY}}"
ARTIFACTS_DIR="${STUDIO_ROOT}/tensorrt_backend/artifacts"

mkdir -p "${STUDIO_DATA}/logs" "${ONNX_DATA}" "${TRT_DATA}" "${STUDIO_ROOT}/tensorrt_backend"

# Make this helper safe to run independently of the normal container entrypoint.
if [[ -L "${ARTIFACTS_DIR}" ]]; then
  current_target="$(readlink -f "${ARTIFACTS_DIR}" 2>/dev/null || true)"
  if [[ "${current_target}" != "${TRT_DATA}" ]]; then
    rm -f "${ARTIFACTS_DIR}"
    ln -s "${TRT_DATA}" "${ARTIFACTS_DIR}"
  fi
elif [[ -e "${ARTIFACTS_DIR}" ]]; then
  # Migrate old real artifact directories before replacing them with the
  # GPU-specific symlink used by this wrapper.
  shopt -s nullglob
  for file in "${ARTIFACTS_DIR}"/*.rtxplan; do
    [[ -e "${TRT_DATA}/$(basename "${file}")" ]] || mv "${file}" "${TRT_DATA}/"
  done
  for file in "${ARTIFACTS_DIR}"/*.onnx; do
    [[ -e "${ONNX_DATA}/$(basename "${file}")" ]] || mv "${file}" "${ONNX_DATA}/"
  done
  shopt -u nullglob
  rm -rf "${ARTIFACTS_DIR}"
  ln -s "${TRT_DATA}" "${ARTIFACTS_DIR}"
else
  ln -s "${TRT_DATA}" "${ARTIFACTS_DIR}"
fi

export STUDIO_ROOT STUDIO_DATA ONNX_DATA TRT_DATA
export HF_ONNX_REPO HF_ONNX_REPO_TYPE HF_ONNX_REVISION

cd "${STUDIO_ROOT}"

echo "============================================================"
echo " SeedVR2 TensorRT preparation"
echo "============================================================"
echo "GPU        : ${GPU_NAME:-unknown}"
echo "ONNX cache : ${ONNX_DATA}"
echo "TRT cache  : ${TRT_DATA}"
echo "HF repo    : ${HF_ONNX_REPO:-<disabled>}"
echo "HF type    : ${HF_ONNX_REPO_TYPE}"
echo "HF revision: ${HF_ONNX_REVISION}"
echo ""
nvidia-smi --query-gpu=name,uuid,driver_version,memory.total --format=csv,noheader || true

echo ""
if [[ -n "${HF_ONNX_REPO}" ]]; then
  echo "Fetching/verifying portable ONNX artifacts..."
  if ! python /usr/local/bin/fetch-onnx; then
    if truthy "${HF_ONNX_ALLOW_EXPORT}"; then
      echo "[warn] Portable ONNX fetch failed; HF_ONNX_ALLOW_EXPORT=${HF_ONNX_ALLOW_EXPORT}, so upstream export is allowed."
    else
      echo "ERROR: Portable ONNX fetch failed." >&2
      echo "ERROR: Refusing to fall back to the expensive local ONNX trace." >&2
      echo "ERROR: Check HF_ONNX_REPO/HF_ONNX_REPO_TYPE/HF_ONNX_REVISION and HF_TOKEN." >&2
      echo "ERROR: To intentionally regenerate ONNX locally, set HF_ONNX_ALLOW_EXPORT=true." >&2
      exit 1
    fi
  fi
else
  if truthy "${HF_ONNX_ALLOW_EXPORT}"; then
    echo "[warn] HF_ONNX_REPO is empty; local upstream ONNX export is allowed."
  else
    echo "ERROR: HF_ONNX_REPO is empty and HF_ONNX_ALLOW_EXPORT is false." >&2
    echo "ERROR: Configure a portable ONNX repository or explicitly allow local export." >&2
    exit 1
  fi
fi

# Upstream expects ONNX beside the GPU-specific plans. Always create symlinks,
# even when their targets are currently missing: if local export is explicitly
# allowed, the exporter will then create the real file in the portable cache.
for stem in \
  vae_encoder_5f_tile512 \
  vae_encoder_21f_tile512 \
  vae_decoder_tile_512_5f \
  vae_decoder_tile_256_21f; do
  shared="${ONNX_DATA}/${stem}.onnx"
  local_path="${TRT_DATA}/${stem}.onnx"
  ln -sfn "${shared}" "${local_path}"
done

# If we deliberately allowed local export and one or more ONNX files are still
# missing, warn about the known high-memory 21-frame trace before continuing.
missing_onnx=false
for stem in \
  vae_encoder_5f_tile512 \
  vae_encoder_21f_tile512 \
  vae_decoder_tile_512_5f \
  vae_decoder_tile_256_21f; do
  [[ -e "${TRT_DATA}/${stem}.onnx" ]] || missing_onnx=true
done

if [[ "${missing_onnx}" == "true" ]]; then
  TOTAL_MIB="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d ' ' || true)"
  echo ""
  echo "[warn] One or more portable ONNX files are missing; upstream will export them locally."
  if [[ "${TOTAL_MIB}" =~ ^[0-9]+$ ]] && (( TOTAL_MIB < 60000 )); then
    echo "[warn] This GPU has ${TOTAL_MIB} MiB VRAM."
    echo "[warn] The 21-frame 512x512 encoder CUDA trace exceeds a 48 GB-class GPU."
    echo "[warn] Upstream may fall back to a very slow CPU export. An 80 GB-class GPU is recommended."
  fi
  echo ""
fi

echo "Downloading/validating the default SeedVR2 model and VAE..."
python scripts/download_models.py 2>&1 | tee "${STUDIO_DATA}/logs/model-prepare.log"

echo "Building missing GPU-specific TensorRT RTX VAE engines from verified ONNX..."
python scripts/prepare_tensorrt.py 2>&1 | tee "${STUDIO_DATA}/logs/tensorrt-prepare.log"

echo "TensorRT preparation complete."
