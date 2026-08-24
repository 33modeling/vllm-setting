#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

if [[ -f "$ENV_FILE" && ! -r "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE exists but is not readable by user '$(id -un)'." >&2
  echo "       Fix permissions (chmod 644) or run as the file owner." >&2
  exit 1
fi

if [[ -f "$ENV_FILE" ]]; then
  # An inherited value (e.g. `PORT=9999 ./health-check.sh`) must win over the
  # config file, whose plain `VAR=value` lines would otherwise clobber it.
  # Snapshot the environment and restore it after sourcing, so the order is
  # command line > config file > built-in default.
  mapfile -d '' -t _preset_env < <(env -0)
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
  for _kv in "${_preset_env[@]}"; do
    [[ "$_kv" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    case "${_kv%%=*}" in SHELLOPTS|BASHOPTS|PWD|OLDPWD) continue ;; esac
    export "$_kv"
  done
  unset _preset_env _kv
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
  echo "       This config targets 2x RTX 2080 Ti; is this the right machine?" >&2
  exit 1
fi
gpu_count="$(nvidia-smi --list-gpus 2>/dev/null | wc -l)"
IFS=',' read -ra requested_gpus <<< "$CUDA_VISIBLE_DEVICES"
if (( gpu_count < ${#requested_gpus[@]} )); then
  echo "ERROR: not enough GPUs: found $gpu_count, need ${#requested_gpus[@]} (CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES)." >&2
  echo "       This config targets 2x RTX 2080 Ti — is this the right machine?" >&2
  exit 1
fi
for gpu_idx in "${requested_gpus[@]}"; do
  if ! [[ "$gpu_idx" =~ ^[0-9]+$ ]] || (( gpu_idx >= gpu_count )); then
    echo "ERROR: CUDA_VISIBLE_DEVICES contains '$gpu_idx' but this machine only has GPU indexes 0..$((gpu_count - 1))." >&2
    echo "       Fix CUDA_VISIBLE_DEVICES in .env (list GPUs with: nvidia-smi -L)." >&2
    exit 1
  fi
done

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
