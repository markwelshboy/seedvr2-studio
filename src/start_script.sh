#!/usr/bin/env bash
set -euo pipefail

STUDIO_ROOT="${STUDIO_ROOT:-/opt/seedvr-studio}"
STUDIO_DATA="${STUDIO_DATA:-/workspace/seedvr2-studio}"
STUDIO_HOST="${STUDIO_HOST:-0.0.0.0}"
STUDIO_PORT="${STUDIO_PORT:-7870}"
ENABLE_BROWSER="${ENABLE_BROWSER:-false}"
VENV="${VENV:-/opt/venv}"
HF_ONNX_REPO="${HF_ONNX_REPO:-markwelshboyx/seedvr2-studio-onnx}"
HF_ONNX_REPO_TYPE="${HF_ONNX_REPO_TYPE:-dataset}"
HF_ONNX_REVISION="${HF_ONNX_REVISION:-main}"

GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || true)"
GPU_KEY="$(printf '%s' "${GPU_NAME:-unknown-gpu}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+|-+$//g')"
GPU_KEY="${GPU_KEY:-unknown-gpu}"
TRT_DATA="${STUDIO_DATA}/tensorrt-artifacts/${GPU_KEY}"
ONNX_DATA="${STUDIO_DATA}/tensorrt-onnx"

mkdir -p \
  "${STUDIO_DATA}/models/SEEDVR2" \
  "${STUDIO_DATA}/outputs" \
  "${TRT_DATA}" \
  "${ONNX_DATA}" \
  "${STUDIO_DATA}/logs" \
  "${HF_HOME:-/workspace/.cache/huggingface}" \
  "${TORCH_HOME:-/workspace/.cache/torch}"

# Keep large mutable state out of the immutable image layer.
mkdir -p "${STUDIO_ROOT}/models" "${STUDIO_ROOT}/tensorrt_backend"
rm -rf "${STUDIO_ROOT}/models/SEEDVR2" "${STUDIO_ROOT}/outputs" "${STUDIO_ROOT}/tensorrt_backend/artifacts"
ln -s "${STUDIO_DATA}/models/SEEDVR2" "${STUDIO_ROOT}/models/SEEDVR2"
ln -s "${STUDIO_DATA}/outputs" "${STUDIO_ROOT}/outputs"
ln -s "${TRT_DATA}" "${STUDIO_ROOT}/tensorrt_backend/artifacts"

# ONNX graphs are portable across GPUs; TensorRT plans are not. Keep the ONNX
# files in a shared cache and expose them inside each GPU-specific artifacts
# directory as symlinks. If an older image already created a real ONNX file in
# the GPU-specific directory, migrate it into the shared cache first.
for stem in \
  vae_encoder_5f_tile512 \
  vae_encoder_21f_tile512 \
  vae_decoder_tile_512_5f \
  vae_decoder_tile_256_21f; do
  local_onnx="${TRT_DATA}/${stem}.onnx"
  shared_onnx="${ONNX_DATA}/${stem}.onnx"
  if [[ -f "${local_onnx}" && ! -L "${local_onnx}" ]]; then
    if [[ ! -e "${shared_onnx}" ]]; then
      mv "${local_onnx}" "${shared_onnx}"
    else
      rm -f "${local_onnx}"
    fi
  fi
  ln -sfn "${shared_onnx}" "${local_onnx}"
done

# RunPod commonly supplies PUBLIC_KEY. SSH is only a recovery path.
mkdir -p /root/.ssh /run/sshd
chmod 700 /root/.ssh
if [[ -n "${PUBLIC_KEY:-${SSH_PUBLIC_KEY:-}}" ]]; then
  printf '%s\n' "${PUBLIC_KEY:-${SSH_PUBLIC_KEY:-}}" > /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
fi
/usr/sbin/sshd || true

cd "${STUDIO_ROOT}"

echo "============================================================"
echo " SeedVR2 TensorRT Studio"
echo "============================================================"
echo "App        : http://0.0.0.0:${STUDIO_PORT}/"
echo "Data       : ${STUDIO_DATA}"
echo "Models     : ${STUDIO_DATA}/models/SEEDVR2"
echo "Outputs    : ${STUDIO_DATA}/outputs"
echo "GPU        : ${GPU_NAME:-unknown}"
echo "ONNX cache : ${ONNX_DATA}"
echo "TRT cache  : ${TRT_DATA}"
echo "ONNX source: ${HF_ONNX_REPO:-<disabled>} (${HF_ONNX_REPO_TYPE}@${HF_ONNX_REVISION})"
echo "Browser    : ${ENABLE_BROWSER}"
echo "Venv       : ${VENV}"
echo "Activate   : source ${VENV}/bin/activate"
echo ""
echo "Optional FlashAttention install:"
echo "  source ${VENV}/bin/activate"
echo "  python -m pip install --no-build-isolation flash-attn"
echo ""
echo "TensorRT engines are GPU-specific. To download verified ONNX and build/refresh plans:"
echo "  prepare-tensorrt"
echo ""

python -m uvicorn api_server:app \
  --host "${STUDIO_HOST}" \
  --port "${STUDIO_PORT}" \
  >"${STUDIO_DATA}/logs/studio.log" 2>&1 &
STUDIO_PID=$!

cleanup() {
  if [[ "${ENABLE_BROWSER}" == "true" ]]; then
    /usr/local/bin/stop-local-browser >/dev/null 2>&1 || true
  fi
  kill "${STUDIO_PID}" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

for _ in $(seq 1 120); do
  if curl -fsS "http://127.0.0.1:${STUDIO_PORT}/api/health" >/dev/null 2>&1; then
    echo "[ok] SeedVR Studio API is ready on ${STUDIO_PORT}"
    break
  fi
  if ! kill -0 "${STUDIO_PID}" >/dev/null 2>&1; then
    echo "[fatal] SeedVR Studio exited during startup" >&2
    tail -200 "${STUDIO_DATA}/logs/studio.log" >&2 || true
    exit 1
  fi
  sleep 1
done

if [[ "${ENABLE_BROWSER}" == "true" ]]; then
  START_URL="${START_URL:-http://127.0.0.1:${STUDIO_PORT}/}" \
    /usr/local/bin/start-local-browser
fi

wait "${STUDIO_PID}"
