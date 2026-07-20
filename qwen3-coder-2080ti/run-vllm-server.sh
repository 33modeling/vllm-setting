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

# vllm executable: VLLM_BIN override > PATH > local .venv-vllm (see README).
if [[ -n "${VLLM_BIN:-}" ]]; then
  if [[ ! -x "$VLLM_BIN" ]]; then
    echo "ERROR: VLLM_BIN='$VLLM_BIN' does not exist or is not executable." >&2
    exit 1
  fi
elif command -v vllm >/dev/null 2>&1; then
  VLLM_BIN="$(command -v vllm)"
elif [[ -x "$SCRIPT_DIR/.venv-vllm/bin/vllm" ]]; then
  VLLM_BIN="$SCRIPT_DIR/.venv-vllm/bin/vllm"
else
  cat >&2 <<'ERR'
ERROR: 'vllm' executable not found.
  Searched: PATH, ./.venv-vllm/bin/vllm
  Install it first (see README):
    python3 -m venv .venv-vllm && source .venv-vllm/bin/activate && pip install -U pip vllm
  Or point VLLM_BIN at an existing install:
    VLLM_BIN=/path/to/venv/bin/vllm ./run-vllm-server.sh
ERR
  exit 1
fi

if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "ERROR: nvidia-smi not found — no NVIDIA driver on this machine?" >&2
  echo "       This config targets 2x RTX 2080 Ti; is this the right machine?" >&2
  exit 1
fi
gpu_count="$(nvidia-smi --list-gpus 2>/dev/null | wc -l)"
IFS=',' read -ra requested_gpus <<< "$CUDA_VISIBLE_DEVICES"
if (( gpu_count < ${#requested_gpus[@]} )) || (( gpu_count < TP_SIZE )); then
  echo "ERROR: not enough GPUs: found $gpu_count, need ${#requested_gpus[@]}" \
       "(CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES, TP_SIZE=$TP_SIZE)." >&2
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

# The AWQ 4-bit 30B checkpoint needs ~11 GB per TP rank.
min_vram_mib="$(nvidia-smi -i "$CUDA_VISIBLE_DEVICES" --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | sort -n | head -1)"
if [[ "$min_vram_mib" =~ ^[0-9]+$ ]] && (( min_vram_mib < 10000 )); then
  echo "ERROR: not enough VRAM: smallest selected GPU has ${min_vram_mib} MiB; this profile targets 11 GB x 2 (2x RTX 2080 Ti)." >&2
  exit 1
fi

if ss -tln 2>/dev/null | awk '{print $4}' | grep -q ":$PORT\$"; then
  echo "ERROR: port $PORT is already in use — is another server running?" >&2
  echo "       Stop it with ./stop-server.sh or change VLLM_PORT in .env." >&2
  exit 1
fi

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
exec "$VLLM_BIN" "${args[@]}" "$@"
