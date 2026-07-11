#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi

MODEL="${VLLM_MODEL:-cyankiwi/Qwen3-Coder-30B-A3B-Instruct-AWQ-4bit}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-qwen3-coder-30b-a3b}"
HOST="${HOST:-127.0.0.1}"
PORT="${VLLM_PORT:-8000}"
TP_SIZE="${VLLM_TP_SIZE:-2}"
MAX_MODEL_LEN="${VLLM_MAX_MODEL_LEN:-8192}"
GPU_MEMORY_UTILIZATION="${VLLM_GPU_MEMORY_UTILIZATION:-0.92}"
MAX_NUM_BATCHED_TOKENS="${VLLM_MAX_NUM_BATCHED_TOKENS:-2048}"
PID_FILE="${VLLM_PID_FILE:-$SCRIPT_DIR/vllm-server.pid}"

export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0,1}"

command -v vllm >/dev/null 2>&1 || {
  echo "vllm is required. Install it in a dedicated virtual environment." >&2
  exit 1
}

args=(
  serve "$MODEL"
  --served-model-name "$SERVED_MODEL_NAME"
  --host "$HOST"
  --port "$PORT"
  --tensor-parallel-size "$TP_SIZE"
  --enable-expert-parallel
  --max-model-len "$MAX_MODEL_LEN"
  --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION"
  --max-num-seqs 1
  --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS"
  --dtype half
  --kv-cache-dtype auto
  --enable-prefix-caching
  --enable-chunked-prefill
  --disable-custom-all-reduce
  --enforce-eager
  --enable-auto-tool-choice
  --tool-call-parser qwen3_coder
)

cat <<EOF
Starting vLLM (best-effort 2x RTX 2080 Ti profile)
  model:                  $MODEL
  api:                    http://$HOST:$PORT/v1
  cuda devices:           $CUDA_VISIBLE_DEVICES
  tensor/expert parallel: $TP_SIZE
  max model len:          $MAX_MODEL_LEN
  gpu memory utilization: $GPU_MEMORY_UTILIZATION

llama.cpp is the recommended backend for this 22 GB VRAM target.
If startup OOMs, lower VLLM_MAX_MODEL_LEN to 4096 before changing other flags.
EOF

echo "$$" > "$PID_FILE"
exec vllm "${args[@]}" "$@"
