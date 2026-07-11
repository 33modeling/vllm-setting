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

LLAMA_SERVER="${LLAMA_SERVER:-$SCRIPT_DIR/llama.cpp/build/bin/llama-server}"
MODEL_PATH="${MODEL_PATH:-$SCRIPT_DIR/models/Qwen3-Coder-30B-A3B-Instruct-Q4_K_S.gguf}"
HOST="${HOST:-127.0.0.1}"
PORT="${LLAMA_PORT:-8080}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-qwen3-coder-30b-a3b}"
CTX_SIZE="${LLAMA_CTX_SIZE:-16384}"
TENSOR_SPLIT="${LLAMA_TENSOR_SPLIT:-1,1}"
CACHE_TYPE_K="${LLAMA_CACHE_TYPE_K:-q8_0}"
CACHE_TYPE_V="${LLAMA_CACHE_TYPE_V:-q8_0}"
PID_FILE="${LLAMA_PID_FILE:-$SCRIPT_DIR/llama-server.pid}"

export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0,1}"

if [[ ! -x "$LLAMA_SERVER" ]]; then
  echo "llama-server not found: $LLAMA_SERVER" >&2
  echo "Run ./install-llama-cpp.sh first." >&2
  exit 1
fi

if [[ ! -s "$MODEL_PATH" ]]; then
  echo "GGUF model not found: $MODEL_PATH" >&2
  echo "Run ./download-gguf.sh first." >&2
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
  --parallel 1
  --jinja
  --temp 0.7
  --top-p 0.8
  --top-k 20
  --repeat-penalty 1.05
)

cat <<EOF
Starting llama.cpp
  model:        $MODEL_PATH
  api:          http://$HOST:$PORT/v1
  cuda devices: $CUDA_VISIBLE_DEVICES
  context:      $CTX_SIZE
  split:        $TENSOR_SPLIT
  KV cache:     $CACHE_TYPE_K / $CACHE_TYPE_V
EOF

echo "$$" > "$PID_FILE"
exec "$LLAMA_SERVER" "${args[@]}" "$@"
