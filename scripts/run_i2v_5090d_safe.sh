#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CKPT_DIR="lingbot-world-base-cam"
IMAGE=""
PROMPT=""
ACTION_PATH=""
ACTION_STRING=""
SIZE="1280*720"
FRAMES="49"
SEED="42"
SAVE_FILE=""
MODE="auto"
GPU_INDEX="0"
MIN_FREE_VRAM_MB="28500"
COUNTDOWN="10"
TIMEOUT_LIMIT="6h"
FORCE="0"
NO_SYSTEMD_SCOPE="0"
SINGBOX_PORT="${SINGBOX_PORT:-}"
HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
ORIGINAL_ARGS=("$@")

usage() {
  cat <<'EOF'
Usage:
  scripts/run_i2v_5090d_safe.sh --image PATH --prompt "text prompt" [options]

Purpose:
  Conservative single-GPU startup script for RTX 5090D 32GB VRAM.
  It avoids distributed/FSDP flags, keeps T5 on CPU, enables model offload,
  checks available VRAM before launch, and defaults to a short 720p run.

Required:
  --image PATH              Starting image for image-to-video.
  --prompt TEXT             Text prompt describing the video.

Safety defaults:
  --mode auto               Uses fast model if lingbot_world_fast exists.
  --frames 49               3.06 seconds at this repo's fixed 16 FPS.
  --size 1280*720           720p landscape. Use 720*1280 for portrait.
  --min-free-vram-mb 28500  Refuse startup if less VRAM is free.
  --timeout 6h              Kill runaway jobs after this wall-clock limit.

Common options:
  --ckpt-dir DIR            Default: lingbot-world-base-cam
  --action-path DIR         Optional control dir with intrinsics.npy and poses.npy.
  --action-string TEXT      Optional keyboard control, e.g. "w-20,none-10,a-20".
  --frames N                Must be 4n+1. Use 49 first, then 81 if stable.
  --size WxH                Usually 1280*720 or 720*1280.
  --save-file PATH          Output .mp4 path.
  --mode auto|fast|full     Default: auto.
  --seed N                  Default: 42.
  --gpu-index N             Default: 0.
  --min-free-vram-mb N      Default: 28500.
  --singbox-port PORT       Optional local SOCKS port, e.g. 1080 or 7890.
  --timeout DURATION        GNU timeout duration. Default: 6h.
  --no-systemd-scope        Do not wrap the run in a user systemd scope.
  --no-countdown            Skip the 10 second Ctrl-C grace period.
  --force                   Bypass VRAM/frame/full-mode safety refusals.

Notes:
  Output FPS is fixed by this repo config at 16 FPS.
  Duration in seconds is frames / 16.
  On 5090D 32GB, start with 49 frames before trying 81 frames.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ckpt-dir) CKPT_DIR="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --action-path) ACTION_PATH="$2"; shift 2 ;;
    --action-string) ACTION_STRING="$2"; shift 2 ;;
    --frames) FRAMES="$2"; shift 2 ;;
    --size) SIZE="$2"; shift 2 ;;
    --save-file) SAVE_FILE="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --seed) SEED="$2"; shift 2 ;;
    --gpu-index) GPU_INDEX="$2"; shift 2 ;;
    --min-free-vram-mb) MIN_FREE_VRAM_MB="$2"; shift 2 ;;
    --singbox-port) SINGBOX_PORT="$2"; shift 2 ;;
    --timeout) TIMEOUT_LIMIT="$2"; shift 2 ;;
    --no-systemd-scope) NO_SYSTEMD_SCOPE="1"; shift ;;
    --no-countdown) COUNTDOWN="0"; shift ;;
    --force) FORCE="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

fail() {
  echo "Refusing to start: $*" >&2
  echo "Use --force only if you understand the risk." >&2
  exit 1
}

if [[ -z "$IMAGE" || -z "$PROMPT" ]]; then
  usage >&2
  exit 2
fi

if [[ ! "$FRAMES" =~ ^[0-9]+$ ]]; then
  echo "--frames must be an integer." >&2
  exit 2
fi

if (( (FRAMES - 1) % 4 != 0 )); then
  echo "--frames must be 4n+1, got: $FRAMES" >&2
  exit 2
fi

case "$MODE" in
  auto|fast|full) ;;
  *) echo "--mode must be one of: auto, fast, full" >&2; exit 2 ;;
esac

if [[ ! -d ".venv" ]]; then
  echo "Missing .venv. Run project setup first." >&2
  exit 1
fi

if [[ ! -f "$IMAGE" ]]; then
  echo "Image not found: $IMAGE" >&2
  exit 1
fi

if [[ ! -d "$CKPT_DIR" ]]; then
  echo "Checkpoint directory not found: $CKPT_DIR" >&2
  exit 1
fi

if [[ -n "$ACTION_STRING" && -z "$ACTION_PATH" ]]; then
  echo "--action-string requires --action-path because intrinsics.npy is read from that directory." >&2
  exit 1
fi

if [[ -n "$ACTION_PATH" ]]; then
  if [[ ! -f "$ACTION_PATH/intrinsics.npy" ]]; then
    echo "Missing required file: $ACTION_PATH/intrinsics.npy" >&2
    exit 1
  fi
  if [[ -z "$ACTION_STRING" && ! -f "$ACTION_PATH/poses.npy" ]]; then
    echo "Missing required file: $ACTION_PATH/poses.npy" >&2
    exit 1
  fi
fi

if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "nvidia-smi not found; cannot do VRAM preflight." >&2
  exit 1
fi

GPU_CSV="$(nvidia-smi --id="$GPU_INDEX" --query-gpu=name,memory.total,memory.free --format=csv,noheader,nounits)"
GPU_NAME="$(awk -F, '{gsub(/^ +| +$/, "", $1); print $1}' <<<"$GPU_CSV")"
GPU_TOTAL_MB="$(awk -F, '{gsub(/^ +| +$/, "", $2); print $2}' <<<"$GPU_CSV")"
GPU_FREE_MB="$(awk -F, '{gsub(/^ +| +$/, "", $3); print $3}' <<<"$GPU_CSV")"

if (( GPU_TOTAL_MB < 30000 )) && [[ "$FORCE" != "1" ]]; then
  fail "GPU $GPU_INDEX reports only ${GPU_TOTAL_MB} MiB total VRAM, expected a 32GB-class card."
fi

if (( GPU_FREE_MB < MIN_FREE_VRAM_MB )) && [[ "$FORCE" != "1" ]]; then
  fail "GPU $GPU_INDEX has ${GPU_FREE_MB} MiB free VRAM, below --min-free-vram-mb ${MIN_FREE_VRAM_MB}."
fi

if (( FRAMES > 81 )) && [[ "$FORCE" != "1" ]]; then
  fail "--frames $FRAMES is above the conservative 5090D limit of 81."
fi

if [[ "$MODE" == "full" && "$FORCE" != "1" ]]; then
  fail "--mode full is intentionally blocked by default on 32GB VRAM. Use fast/auto first."
fi

source .venv/bin/activate

export CUDA_VISIBLE_DEVICES="$GPU_INDEX"
export HF_ENDPOINT
export TOKENIZERS_PARALLELISM=false
export CUDA_MODULE_LOADING="${CUDA_MODULE_LOADING:-LAZY}"
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True,max_split_size_mb:128}"
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-4}"
export MKL_NUM_THREADS="${MKL_NUM_THREADS:-4}"
export NUMEXPR_NUM_THREADS="${NUMEXPR_NUM_THREADS:-4}"

if [[ -n "$SINGBOX_PORT" ]]; then
  export ALL_PROXY="socks5h://127.0.0.1:${SINGBOX_PORT}"
  export HTTP_PROXY="$ALL_PROXY"
  export HTTPS_PROXY="$ALL_PROXY"
  export NO_PROXY="127.0.0.1,localhost"
fi

USE_FAST=0
if [[ "$MODE" == "fast" ]]; then
  USE_FAST=1
elif [[ "$MODE" == "auto" && -d "$CKPT_DIR/lingbot_world_fast" ]]; then
  USE_FAST=1
fi

if [[ "$MODE" == "fast" && ! -d "$CKPT_DIR/lingbot_world_fast" ]]; then
  echo "Fast checkpoint not found: $CKPT_DIR/lingbot_world_fast" >&2
  exit 1
fi

COMMON_ARGS=(
  --task i2v-A14B
  --size "$SIZE"
  --ckpt_dir "$CKPT_DIR"
  --image "$IMAGE"
  --frame_num "$FRAMES"
  --prompt "$PROMPT"
  --base_seed "$SEED"
  --t5_cpu
  --offload_model true
)

if [[ -n "$ACTION_PATH" ]]; then
  COMMON_ARGS+=(--action_path "$ACTION_PATH")
fi

if [[ -n "$SAVE_FILE" ]]; then
  COMMON_ARGS+=(--save_file "$SAVE_FILE")
fi

if [[ "$USE_FAST" == "1" ]]; then
  RUNNER="generate_fast.py"
  RUN_ARGS=("${COMMON_ARGS[@]}")
else
  RUNNER="generate.py"
  RUN_ARGS=("${COMMON_ARGS[@]}")
  if [[ -n "$ACTION_STRING" ]]; then
    RUN_ARGS+=(--action_string "$ACTION_STRING" --allow_act2cam)
  fi
fi

HOST_MEMORY_MAX_BYTES=""
if [[ -r /proc/meminfo ]]; then
  HOST_MEMORY_TOTAL_KB="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)"
  HOST_MEMORY_MAX_BYTES="$((HOST_MEMORY_TOTAL_KB * 1024 * 85 / 100))"
fi

if [[ "$NO_SYSTEMD_SCOPE" == "0" && "${LINGBOT_5090D_SCOPED:-0}" != "1" ]] &&
  command -v systemd-run >/dev/null 2>&1 &&
  systemctl --user show-environment >/dev/null 2>&1; then
  export LINGBOT_5090D_SCOPED=1
  if [[ -n "$HOST_MEMORY_MAX_BYTES" ]]; then
    exec systemd-run --user --scope --quiet \
      -p "MemoryMax=${HOST_MEMORY_MAX_BYTES}" \
      -p "CPUQuota=500%" \
      -p "WorkingDirectory=${ROOT_DIR}" \
      "$ROOT_DIR/scripts/run_i2v_5090d_safe.sh" "${ORIGINAL_ARGS[@]}"
  else
    exec systemd-run --user --scope --quiet \
      -p "CPUQuota=500%" \
      -p "WorkingDirectory=${ROOT_DIR}" \
      "$ROOT_DIR/scripts/run_i2v_5090d_safe.sh" "${ORIGINAL_ARGS[@]}"
  fi
fi

echo "GPU: ${GPU_NAME}, total ${GPU_TOTAL_MB} MiB, free ${GPU_FREE_MB} MiB"
echo "Mode: $([[ "$USE_FAST" == "1" ]] && echo fast || echo full)"
echo "Runner: $RUNNER"
echo "Frames: ${FRAMES} at 16 FPS = $(awk "BEGIN { printf \"%.2f\", ${FRAMES}/16 }") seconds"
echo "Size: $SIZE"
echo "Offload: true, T5 on CPU, FSDP disabled, CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"
echo "Timeout: $TIMEOUT_LIMIT"

if (( COUNTDOWN > 0 )); then
  echo "Starting in ${COUNTDOWN}s. Press Ctrl-C to abort."
  sleep "$COUNTDOWN"
fi

exec timeout --foreground "$TIMEOUT_LIMIT" nice -n 5 python "$RUNNER" "${RUN_ARGS[@]}"
