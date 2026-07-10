#!/usr/bin/env bash
set -euo pipefail

# 2x RTX 4090 single-user coding profile for Qwen3.6-27B.
# Copy .env.example to .env to override defaults without editing this file.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/.env"
  set +a
fi

MODEL="${MODEL:-Qwen/Qwen3.6-27B-FP8}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-qwen3.6-27b}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8000}"
PID_FILE="${PID_FILE:-$SCRIPT_DIR/vllm.pid}"

export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0,1}"

TP_SIZE="${TP_SIZE:-2}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-65536}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.90}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-1}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-8192}"
DTYPE="${DTYPE:-auto}"
KV_CACHE_DTYPE="${KV_CACHE_DTYPE:-auto}"

ENABLE_PREFIX_CACHING="${ENABLE_PREFIX_CACHING:-1}"
ENABLE_CHUNKED_PREFILL="${ENABLE_CHUNKED_PREFILL:-1}"
DISABLE_CUSTOM_ALL_REDUCE="${DISABLE_CUSTOM_ALL_REDUCE:-1}"
ENABLE_TOOL_CALLS="${ENABLE_TOOL_CALLS:-0}"
TRUST_REMOTE_CODE="${TRUST_REMOTE_CODE:-0}"

args=(
  serve "$MODEL"
  --served-model-name "$SERVED_MODEL_NAME"
  --host "$HOST"
  --port "$PORT"
  --tensor-parallel-size "$TP_SIZE"
  --max-model-len "$MAX_MODEL_LEN"
  --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION"
  --max-num-seqs "$MAX_NUM_SEQS"
  --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS"
  --dtype "$DTYPE"
  --kv-cache-dtype "$KV_CACHE_DTYPE"
  --reasoning-parser qwen3
  --language-model-only
)

if [[ "$ENABLE_PREFIX_CACHING" == "1" ]]; then
  args+=(--enable-prefix-caching)
fi

if [[ "$ENABLE_CHUNKED_PREFILL" == "1" ]]; then
  args+=(--enable-chunked-prefill)
fi

if [[ "$DISABLE_CUSTOM_ALL_REDUCE" == "1" ]]; then
  args+=(--disable-custom-all-reduce)
fi

if [[ "$ENABLE_TOOL_CALLS" == "1" ]]; then
  args+=(--enable-auto-tool-choice --tool-call-parser qwen3_coder)
fi

if [[ "$TRUST_REMOTE_CODE" == "1" ]]; then
  args+=(--trust-remote-code)
fi

cat <<EOF
Starting vLLM
  model:                  $MODEL
  served model name:      $SERVED_MODEL_NAME
  api:                    http://$HOST:$PORT/v1
  cuda devices:           $CUDA_VISIBLE_DEVICES
  tensor parallel:        $TP_SIZE
  max model len:          $MAX_MODEL_LEN
  max num seqs:           $MAX_NUM_SEQS
  max batched tokens:     $MAX_NUM_BATCHED_TOKENS
  gpu memory utilization: $GPU_MEMORY_UTILIZATION
  kv cache dtype:         $KV_CACHE_DTYPE
  pid file:               $PID_FILE
EOF

echo "$$" > "$PID_FILE"
exec vllm "${args[@]}" "$@"
