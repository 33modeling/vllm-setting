#!/usr/bin/env bash
set -euo pipefail

# Qwen3.8-27B (BF16) on 2x H100 80GB.
#
# 160 GB of HBM is enough to hold the unquantized checkpoint (~54 GB) and still
# serve the full 262,144-token native context, so this profile runs the base
# weights rather than a quantized copy. Multi-user defaults: several concurrent
# sequences, large prefill batches, vision tower left enabled.
#
# Knobs come from the environment or from qwen38-27b-h100x2.env next to this
# script. The shared .env is NOT sourced — it pins the Qwen3.6 model and would
# silently override MODEL here.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/qwen38-27b-h100x2.env}"

if [[ -f "$ENV_FILE" && ! -r "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE exists but is not readable by user '$(id -un)'." >&2
  echo "       Fix permissions (chmod 644 '$ENV_FILE') or run as the file owner." >&2
  exit 1
fi

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi

MODEL="${MODEL:-Qwen/Qwen3.8-27B}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-qwen3.8-27b}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8000}"
PID_FILE="${PID_FILE:-$SCRIPT_DIR/vllm-qwen38-h100x2.pid}"

export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0,1}"

TP_SIZE="${TP_SIZE:-2}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.92}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-16}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-16384}"
DTYPE="${DTYPE:-auto}"
# The 16 full-attention layers dominate KV at 262K; fp8 KV is what makes the
# native context fit alongside 16 concurrent sequences.
KV_CACHE_DTYPE="${KV_CACHE_DTYPE:-fp8}"

ENABLE_PREFIX_CACHING="${ENABLE_PREFIX_CACHING:-1}"
ENABLE_CHUNKED_PREFILL="${ENABLE_CHUNKED_PREFILL:-1}"
# H100 pairs are NVLinked, so the custom all-reduce kernel is a win here —
# unlike the 4090 profile, which has to fall back to NCCL over PCIe.
DISABLE_CUSTOM_ALL_REDUCE="${DISABLE_CUSTOM_ALL_REDUCE:-0}"
ENABLE_TOOL_CALLS="${ENABLE_TOOL_CALLS:-1}"
TRUST_REMOTE_CODE="${TRUST_REMOTE_CODE:-0}"
# Qwen3.8 is natively multimodal. Set to 1 to drop the vision tower when this
# server only ever sees text.
LANGUAGE_MODEL_ONLY="${LANGUAGE_MODEL_ONLY:-0}"
# MTP draft head. Off by default: it only helps low-concurrency latency and
# needs the speculative module present in the checkpoint.
ENABLE_MTP="${ENABLE_MTP:-0}"
MTP_NUM_SPECULATIVE_TOKENS="${MTP_NUM_SPECULATIVE_TOKENS:-3}"

# --- Preflight checks: fail fast with actionable messages -------------------

# 1) vllm executable: VLLM_BIN override > PATH > repo-local .venv.
if [[ -n "${VLLM_BIN:-}" ]]; then
  if [[ ! -x "$VLLM_BIN" ]]; then
    echo "ERROR: VLLM_BIN='$VLLM_BIN' does not exist or is not executable." >&2
    exit 1
  fi
elif command -v vllm >/dev/null 2>&1; then
  VLLM_BIN="$(command -v vllm)"
elif [[ -x "$SCRIPT_DIR/.venv/bin/vllm" ]]; then
  VLLM_BIN="$SCRIPT_DIR/.venv/bin/vllm"
else
  cat >&2 <<'ERR'
ERROR: 'vllm' executable not found.
  Searched: PATH, ./.venv/bin/vllm
  vLLM may not be installed on this machine. Install it first (see README):
    uv venv && source .venv/bin/activate && uv pip install -U vllm --torch-backend=auto
  Or point VLLM_BIN at an existing install:
    VLLM_BIN=/path/to/venv/bin/vllm ./run-qwen38-27b-h100x2.sh
ERR
  exit 1
fi

# 2) vLLM version: Qwen3.8 is a hybrid (linear attention on 48 of 64 layers)
#    and needs 0.17.0+. Warn rather than block — version strings vary on nightlies.
vllm_version="$("$VLLM_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
if [[ -n "$vllm_version" ]]; then
  if [[ "$(printf '%s\n0.17.0\n' "$vllm_version" | sort -V | head -1)" != "0.17.0" ]]; then
    echo "WARNING: vLLM $vllm_version detected; Qwen3.8 needs 0.17.0+ for its hybrid" >&2
    echo "         attention layers. Expect an unsupported-architecture error." >&2
  fi
fi

# 3) GPUs: need a driver and at least as many GPUs as CUDA_VISIBLE_DEVICES/TP_SIZE.
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "ERROR: nvidia-smi not found — no NVIDIA driver on this machine?" >&2
  echo "       This config targets 2x H100 80GB; run it on the GPU server." >&2
  exit 1
fi
gpu_count="$(nvidia-smi --list-gpus 2>/dev/null | wc -l)"
IFS=',' read -ra requested_gpus <<< "$CUDA_VISIBLE_DEVICES"
if (( gpu_count < ${#requested_gpus[@]} )) || (( gpu_count < TP_SIZE )); then
  echo "ERROR: not enough GPUs: found $gpu_count, need ${#requested_gpus[@]}" \
       "(CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES, TP_SIZE=$TP_SIZE)." >&2
  echo "       This config targets 2x H100 80GB — is this the right machine?" >&2
  exit 1
fi
for gpu_idx in "${requested_gpus[@]}"; do
  if ! [[ "$gpu_idx" =~ ^[0-9]+$ ]] || (( gpu_idx >= gpu_count )); then
    echo "ERROR: CUDA_VISIBLE_DEVICES contains '$gpu_idx' but this machine only has GPU indexes 0..$((gpu_count - 1))." >&2
    echo "       Fix CUDA_VISIBLE_DEVICES in $ENV_FILE (list GPUs with: nvidia-smi -L)." >&2
    exit 1
  fi
done

# 4) VRAM: BF16 weights are ~54 GB, so each rank needs a real 80 GB card.
if [[ "$MODEL" == "Qwen/Qwen3.8-27B" ]]; then
  min_vram_mib="$(nvidia-smi -i "$CUDA_VISIBLE_DEVICES" --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | sort -n | head -1)"
  if [[ "$min_vram_mib" =~ ^[0-9]+$ ]] && (( min_vram_mib < 70000 )); then
    echo "ERROR: not enough VRAM for $MODEL: smallest selected GPU has ${min_vram_mib} MiB, need ~81920 MiB per GPU." >&2
    echo "       For 24 GB cards use ./run-qwen38-27b-4090x2.sh (FP8) instead." >&2
    exit 1
  fi
fi

# 5) MODEL: a local path must exist; a HuggingFace ID is downloaded on first run.
if [[ "$MODEL" == /* || "$MODEL" == ./* ]]; then
  if [[ ! -e "$MODEL" ]]; then
    echo "ERROR: MODEL points to a local path that does not exist: $MODEL" >&2
    echo "       Fix MODEL in $ENV_FILE, or use a HuggingFace ID to auto-download." >&2
    exit 1
  fi
fi

# 6) Port must be free.
if ss -tln 2>/dev/null | awk '{print $4}' | grep -q ":$PORT\$"; then
  echo "ERROR: port $PORT is already in use — is another server running?" >&2
  echo "       Stop it with PID_FILE='$PID_FILE' ./stop-vllm.sh or change PORT." >&2
  exit 1
fi

# 7) Soft warnings: small /dev/shm breaks NCCL; low disk breaks the first download.
shm_kib="$(df -k /dev/shm 2>/dev/null | awk 'NR==2 {print $2}')"
if [[ "$shm_kib" =~ ^[0-9]+$ ]] && (( shm_kib < 1048576 )); then
  echo "WARNING: /dev/shm is only $((shm_kib / 1024)) MiB; NCCL may fail with TP_SIZE=$TP_SIZE." >&2
fi
if [[ "$MODEL" != /* && "$MODEL" != ./* ]]; then
  hf_hub_dir="${HF_HOME:-$HOME/.cache/huggingface}/hub/models--${MODEL//\//--}"
  if [[ ! -d "$hf_hub_dir" ]]; then
    avail_gib="$(df -BG --output=avail "$HOME" 2>/dev/null | awk 'NR==2 {gsub(/G/,""); print $1}')"
    if [[ "$avail_gib" =~ ^[0-9]+$ ]] && (( avail_gib < 70 )); then
      echo "WARNING: model not downloaded yet and only ${avail_gib} GiB free — BF16 weights need ~55 GiB." >&2
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
)

if [[ "$LANGUAGE_MODEL_ONLY" == "1" ]]; then
  args+=(--language-model-only)
fi

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

if [[ "$ENABLE_MTP" == "1" ]]; then
  args+=(--speculative-config "{\"method\":\"mtp\",\"num_speculative_tokens\":$MTP_NUM_SPECULATIVE_TOKENS}")
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
  language model only:    $LANGUAGE_MODEL_ONLY
  mtp speculative:        $ENABLE_MTP
  env file:               $ENV_FILE
  pid file:               $PID_FILE
  vllm bin:               $VLLM_BIN

  stop with: PID_FILE='$PID_FILE' PORT=$PORT ./stop-vllm.sh
EOF

echo "$$" > "$PID_FILE"
exec "$VLLM_BIN" "${args[@]}" "$@"
