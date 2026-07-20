#!/usr/bin/env bash
set -euo pipefail

# 2x RTX 4090 profile for Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive (GGUF).
# Copy .env.example to .env to override defaults without editing this file.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

if [[ -f "$ENV_FILE" && ! -r "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE exists but is not readable by user '$(id -un)'." >&2
  echo "       Fix permissions (chmod 644) or run as the file owner." >&2
  exit 1
fi

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi

LLAMA_SERVER="${LLAMA_SERVER:-$SCRIPT_DIR/llama.cpp/build/bin/llama-server}"
GGUF_QUANT="${GGUF_QUANT:-Q6_K_P}"
MODEL_PATH="${MODEL_PATH:-$SCRIPT_DIR/models/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-${GGUF_QUANT}.gguf}"
HOST="${HOST:-127.0.0.1}"
PORT="${LLAMA_PORT:-8080}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-qwen3.6-35b-uncensored}"
CTX_SIZE="${LLAMA_CTX_SIZE:-131072}"
TENSOR_SPLIT="${LLAMA_TENSOR_SPLIT:-1,1}"
CACHE_TYPE_K="${LLAMA_CACHE_TYPE_K:-f16}"
CACHE_TYPE_V="${LLAMA_CACHE_TYPE_V:-f16}"
PARALLEL="${LLAMA_PARALLEL:-1}"
TEMP="${LLAMA_TEMP:-0.6}"
TOP_P="${LLAMA_TOP_P:-0.95}"
TOP_K="${LLAMA_TOP_K:-20}"
MIN_P="${LLAMA_MIN_P:-0}"
PID_FILE="${LLAMA_PID_FILE:-$SCRIPT_DIR/llama-server.pid}"

export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0,1}"

if [[ ! -x "$LLAMA_SERVER" ]]; then
  echo "ERROR: llama-server not found: $LLAMA_SERVER" >&2
  echo "       Run ./install-llama-cpp.sh first, or point LLAMA_SERVER at your build." >&2
  exit 1
fi

if [[ ! -s "$MODEL_PATH" ]]; then
  echo "ERROR: GGUF model not found: $MODEL_PATH" >&2
  echo "       Run ./download-gguf.sh first, or point MODEL_PATH at your .gguf file." >&2
  exit 1
fi

if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "ERROR: nvidia-smi not found — no NVIDIA driver on this machine?" >&2
  echo "       This config targets 2x RTX 4090; is this the right machine?" >&2
  exit 1
fi
gpu_count="$(nvidia-smi --list-gpus 2>/dev/null | wc -l)"
IFS=',' read -ra requested_gpus <<< "$CUDA_VISIBLE_DEVICES"
if (( gpu_count < ${#requested_gpus[@]} )); then
  echo "ERROR: not enough GPUs: found $gpu_count, need ${#requested_gpus[@]} (CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES)." >&2
  echo "       This config targets 2x RTX 4090 — is this the right machine?" >&2
  exit 1
fi
for gpu_idx in "${requested_gpus[@]}"; do
  if ! [[ "$gpu_idx" =~ ^[0-9]+$ ]] || (( gpu_idx >= gpu_count )); then
    echo "ERROR: CUDA_VISIBLE_DEVICES contains '$gpu_idx' but this machine only has GPU indexes 0..$((gpu_count - 1))." >&2
    echo "       Fix CUDA_VISIBLE_DEVICES in .env (list GPUs with: nvidia-smi -L)." >&2
    exit 1
  fi
done

# Free-VRAM check: the root vLLM server shares these GPUs and holds ~90% of
# each card, so starting on top of it always fails late — fail early instead.
if [[ "${SKIP_VRAM_CHECK:-0}" != "1" ]]; then
  model_bytes="$(stat -c %s "$MODEL_PATH")"
  need_mib=$(( model_bytes / 1048576 / ${#requested_gpus[@]} + 4096 ))
  while IFS=, read -r idx free_mib; do
    idx="${idx// /}"; free_mib="${free_mib// /}"
    [[ "$free_mib" =~ ^[0-9]+$ ]] || continue
    if (( free_mib < need_mib )); then
      echo "ERROR: GPU $idx has only ${free_mib} MiB free, need ~${need_mib} MiB (weights/${#requested_gpus[@]} + KV/buffers)." >&2
      echo "       Is the vLLM 27B server still running? Stop it first:" >&2
      echo "         ../stop-vllm.sh   (or: systemctl --user stop vllm-qwen36.service)" >&2
      echo "       To skip this check: SKIP_VRAM_CHECK=1 ./run-llama-server.sh" >&2
      exit 1
    fi
  done < <(nvidia-smi -i "$CUDA_VISIBLE_DEVICES" --query-gpu=index,memory.free --format=csv,noheader,nounits 2>/dev/null)
fi

if ss -tln 2>/dev/null | awk '{print $4}' | grep -q ":$PORT\$"; then
  echo "ERROR: port $PORT is already in use — is another server running?" >&2
  echo "       Stop it with ./stop-server.sh or change LLAMA_PORT in .env." >&2
  exit 1
fi

args=(
  --model "$MODEL_PATH"
  --alias "$SERVED_MODEL_NAME"
  --host "$HOST"
  --port "$PORT"
  --ctx-size "$CTX_SIZE"
  --n-gpu-layers all
  --split-mode layer
  --tensor-split "$TENSOR_SPLIT"
  --cache-type-k "$CACHE_TYPE_K"
  --cache-type-v "$CACHE_TYPE_V"
  --flash-attn auto
  --parallel "$PARALLEL"
  --jinja
  --temp "$TEMP"
  --top-p "$TOP_P"
  --top-k "$TOP_K"
  --min-p "$MIN_P"
)

# Vision input is optional; text-only serving skips the mmproj entirely.
if [[ -n "${LLAMA_MMPROJ:-}" ]]; then
  if [[ ! -s "$LLAMA_MMPROJ" ]]; then
    echo "ERROR: LLAMA_MMPROJ points to a missing file: $LLAMA_MMPROJ" >&2
    echo "       Download it with: DOWNLOAD_MMPROJ=1 ./download-gguf.sh" >&2
    exit 1
  fi
  args+=(--mmproj "$LLAMA_MMPROJ")
fi

cat <<EOF
Starting llama.cpp
  model:        $MODEL_PATH
  api:          http://$HOST:$PORT/v1
  alias:        $SERVED_MODEL_NAME
  cuda devices: $CUDA_VISIBLE_DEVICES
  context:      $CTX_SIZE
  parallel:     $PARALLEL
  split:        $TENSOR_SPLIT
  KV cache:     $CACHE_TYPE_K / $CACHE_TYPE_V
  sampling:     temp=$TEMP top_p=$TOP_P top_k=$TOP_K min_p=$MIN_P
EOF

echo "$$" > "$PID_FILE"
exec "$LLAMA_SERVER" "${args[@]}" "$@"
