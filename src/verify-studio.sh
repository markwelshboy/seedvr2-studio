#!/usr/bin/env bash
set -euo pipefail
STUDIO_ROOT="${STUDIO_ROOT:-/opt/seedvr-studio}"
cd "${STUDIO_ROOT}"
python - <<'PY'
import sys
import torch
import tensorrt_rtx

print("Python:", sys.version.split()[0])
print("Torch:", torch.__version__)
print("Torch CUDA:", torch.version.cuda)
print("CUDA available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("GPU:", torch.cuda.get_device_name(0))

sys.path.insert(0, "vendor/seedvr2")
from src.optimization.compatibility import SAGE_ATTN_2_AVAILABLE
print("SageAttention 2:", SAGE_ATTN_2_AVAILABLE)
print("TensorRT RTX:", getattr(tensorrt_rtx, "__version__", "imported"))
PY
