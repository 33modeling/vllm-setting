#!/usr/bin/env bash
set -euo pipefail

# 2x RTX 4090 single-user coding profile for Qwen3.6-27B.
# Copy .env.example to .env to override defaults without editing this file.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

if [[ -f "$REPO_ROOT/.env" && ! -r "$REPO_ROOT/.env" ]]; then
  echo "ERROR: $REPO_ROOT/.env exists but is not readable by user '$(id -un)'." >&2
  echo "       Fix permissions (chmod 644 .env) or run as the file owner." >&2
  exit 1
fi

if [[ -f "$REPO_ROOT/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.env"
  set +a
fi

MODEL="${MODEL:-Qwen/Qwen3.6-27B-FP8}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-qwen3.6-27b-fp8}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8000}"
PID_FILE="${PID_FILE:-$REPO_ROOT/vllm.pid}"

export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0,1}"

TP_SIZE="${TP_SIZE:-2}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-65536}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.90}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-2}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-8192}"
DTYPE="${DTYPE:-auto}"
KV_CACHE_DTYPE="${KV_CACHE_DTYPE:-auto}"

ENABLE_PREFIX_CACHING="${ENABLE_PREFIX_CACHING:-1}"
ENABLE_CHUNKED_PREFILL="${ENABLE_CHUNKED_PREFILL:-1}"
DISABLE_CUSTOM_ALL_REDUCE="${DISABLE_CUSTOM_ALL_REDUCE:-1}"
ENABLE_TOOL_CALLS="${ENABLE_TOOL_CALLS:-1}"
TRUST_REMOTE_CODE="${TRUST_REMOTE_CODE:-0}"

# --- Preflight checks: fail fast with actionable messages -------------------

# 1) vllm executable: VLLM_BIN override > PATH > repo-local .venv.
if [[ -n "${VLLM_BIN:-}" ]]; then
  if [[ ! -x "$VLLM_BIN" ]]; then
    echo "ERROR: VLLM_BIN='$VLLM_BIN' does not exist or is not executable." >&2
    exit 1
  fi
elif command -v vllm >/dev/null 2>&1; then
  VLLM_BIN="$(command -v vllm)"
elif [[ -x "$REPO_ROOT/.venv/bin/vllm" ]]; then
  VLLM_BIN="$REPO_ROOT/.venv/bin/vllm"
else
  cat >&2 <<'ERR'
ERROR: 'vllm' executable not found.
  Searched: PATH, ./.venv/bin/vllm
  vLLM may not be installed on this machine. Install it first (see README):
    uv venv && source .venv/bin/activate && uv pip install -U vllm --torch-backend=auto
  Or point VLLM_BIN at an existing install:
    VLLM_BIN=/path/to/venv/bin/vllm ./targets/qwen36-27b-4090x2.sh
ERR
  exit 1
fi

# 2) GPUs: need a driver and at least as many GPUs as CUDA_VISIBLE_DEVICES/TP_SIZE.
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "ERROR: nvidia-smi not found — no NVIDIA driver on this machine?" >&2
  echo "       This config targets 2x RTX 4090; run it on the GPU server." >&2
  exit 1
fi
gpu_count="$(nvidia-smi --list-gpus 2>/dev/null | wc -l)"
IFS=',' read -ra requested_gpus <<< "$CUDA_VISIBLE_DEVICES"
if (( gpu_count < ${#requested_gpus[@]} )) || (( gpu_count < TP_SIZE )); then
  echo "ERROR: not enough GPUs: found $gpu_count, need ${#requested_gpus[@]}" \
       "(CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES, TP_SIZE=$TP_SIZE)." >&2
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

# 3) VRAM: the default 27B-FP8 model needs a ~24 GB card per TP rank.
if [[ "$MODEL" == "Qwen/Qwen3.6-27B-FP8" ]]; then
  min_vram_mib="$(nvidia-smi -i "$CUDA_VISIBLE_DEVICES" --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | sort -n | head -1)"
  if [[ "$min_vram_mib" =~ ^[0-9]+$ ]] && (( min_vram_mib < 20000 )); then
    echo "ERROR: not enough VRAM for $MODEL: smallest selected GPU has ${min_vram_mib} MiB, need ~24576 MiB per GPU." >&2
    echo "       This config targets 2x RTX 4090. Set a smaller MODEL in .env, or run on the GPU server." >&2
    exit 1
  fi
fi

# 4) MODEL: a local path must exist; a HuggingFace ID is downloaded on first run.
if [[ "$MODEL" == /* || "$MODEL" == ./* ]]; then
  if [[ ! -e "$MODEL" ]]; then
    echo "ERROR: MODEL points to a local path that does not exist: $MODEL" >&2
    echo "       Fix MODEL in .env, or use a HuggingFace ID to auto-download." >&2
    exit 1
  fi
fi

# 5) Port must be free.
if ss -tln 2>/dev/null | awk '{print $4}' | grep -q ":$PORT\$"; then
  echo "ERROR: port $PORT is already in use — is another server running?" >&2
  echo "       Stop it with ./stop-vllm.sh or change PORT in .env." >&2
  exit 1
fi

# 6) Soft warnings: small /dev/shm breaks NCCL; low disk breaks the first download.
shm_kib="$(df -k /dev/shm 2>/dev/null | awk 'NR==2 {print $2}')"
if [[ "$shm_kib" =~ ^[0-9]+$ ]] && (( shm_kib < 1048576 )); then
  echo "WARNING: /dev/shm is only $((shm_kib / 1024)) MiB; NCCL may fail with TP_SIZE=$TP_SIZE." >&2
fi
if [[ "$MODEL" != /* && "$MODEL" != ./* ]]; then
  hf_hub_dir="${HF_HOME:-$HOME/.cache/huggingface}/hub/models--${MODEL//\//--}"
  if [[ ! -d "$hf_hub_dir" ]]; then
    avail_gib="$(df -BG --output=avail "$HOME" 2>/dev/null | awk 'NR==2 {gsub(/G/,""); print $1}')"
    if [[ "$avail_gib" =~ ^[0-9]+$ ]] && (( avail_gib < 40 )); then
      echo "WARNING: model not downloaded yet and only ${avail_gib} GiB free — the default model needs ~30 GiB." >&2
    fi
  fi
fi

# ----------------------------------------------------------------------------

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
  vllm bin:               $VLLM_BIN
EOF

echo "$$" > "$PID_FILE"
exec "$VLLM_BIN" "${args[@]}" "$@"
