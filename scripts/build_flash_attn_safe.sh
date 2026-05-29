#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

JOBS="${JOBS:-1}"
TIMEOUT="${TIMEOUT:-90m}"
MEMORY_MAX="${MEMORY_MAX:-42G}"
CPU_QUOTA="${CPU_QUOTA:-200%}"
CUDA_ARCH="${TORCH_CUDA_ARCH_LIST:-12.0}"
FLASH_ATTN_CUDA_ARCHS="${FLASH_ATTN_CUDA_ARCHS:-120}"
INDEX_URL="${INDEX_URL:-https://pypi.tuna.tsinghua.edu.cn/simple}"
EXTRA_INDEX_URL="${EXTRA_INDEX_URL:-https://pypi.org/simple}"

usage() {
  cat <<'EOF'
Usage:
  scripts/build_flash_attn_safe.sh

Environment overrides:
  JOBS=1                         Ninja/CUDA compiler jobs. Default: 1.
  TIMEOUT=90m                    Kill build after this duration. Default: 90m.
  MEMORY_MAX=42G                 systemd memory cap when available. Default: 42G.
  CPU_QUOTA=200%                 systemd CPU cap when available. Default: 200%.
  TORCH_CUDA_ARCH_LIST=12.0      CUDA arch to compile. Default: 12.0 for RTX 5090 class GPUs.
  FLASH_ATTN_CUDA_ARCHS=120      FlashAttention arch list. Default: 120 only.
  INDEX_URL=...                  Primary PyPI index. Default: Tsinghua mirror.
  EXTRA_INDEX_URL=...            Fallback PyPI index. Default: pypi.org.

This script intentionally avoids `uv run`.
It expects `.venv` to already contain torch, then builds flash-attn with:
  - one compiler job by default
  - lower CPU and IO priority
  - a timeout
  - a reduced CUDA arch list
  - optional systemd-run memory/CPU limits
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ ! -x ".venv/bin/python" ]]; then
  echo "Missing .venv/bin/python. Recreate the project venv before building flash-attn." >&2
  exit 1
fi

if ! command -v uv >/dev/null 2>&1; then
  echo "Missing uv on PATH." >&2
  exit 1
fi

if ! .venv/bin/python - <<'PY'
import torch
print(torch.__version__)
PY
then
  echo "Torch is not importable from .venv; install torch before flash-attn." >&2
  exit 1
fi

if uv pip list --python .venv/bin/python | rg -q '^flash-attn[[:space:]]'; then
  echo "flash-attn is already installed. Set FORCE=1 to rebuild/reinstall."
  if [[ "${FORCE:-0}" != "1" ]]; then
    exit 0
  fi
fi

echo "Building flash-attn with guarded settings:"
echo "  JOBS=$JOBS"
echo "  TIMEOUT=$TIMEOUT"
echo "  MEMORY_MAX=$MEMORY_MAX"
echo "  CPU_QUOTA=$CPU_QUOTA"
echo "  TORCH_CUDA_ARCH_LIST=$CUDA_ARCH"
echo "  FLASH_ATTN_CUDA_ARCHS=$FLASH_ATTN_CUDA_ARCHS"
echo "  INDEX_URL=$INDEX_URL"

BUILD_CMD=(
  env
  "MAX_JOBS=$JOBS"
  "NVCC_THREADS=1"
  "TORCH_CUDA_ARCH_LIST=$CUDA_ARCH"
  "FLASH_ATTN_CUDA_ARCHS=$FLASH_ATTN_CUDA_ARCHS"
  "UV_HTTP_TIMEOUT=600"
  "UV_LINK_MODE=copy"
  "UV_NO_PROGRESS=1"
  uv pip install
  --python .venv/bin/python
  --index-url "$INDEX_URL"
  --extra-index-url "$EXTRA_INDEX_URL"
  --index-strategy unsafe-best-match
  --no-build-isolation
  flash-attn
)

run_build() {
  timeout "$TIMEOUT" nice -n 10 ionice -c2 -n7 "${BUILD_CMD[@]}"
}

if command -v systemd-run >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  systemd-run --user --scope \
    -p "MemoryMax=$MEMORY_MAX" \
    -p "CPUQuota=$CPU_QUOTA" \
    timeout "$TIMEOUT" nice -n 10 ionice -c2 -n7 "${BUILD_CMD[@]}"
else
  run_build
fi

echo "Verifying flash-attn package registration..."
uv pip list --python .venv/bin/python | rg '^flash-attn[[:space:]]'
