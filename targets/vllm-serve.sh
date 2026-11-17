#!/usr/bin/env bash
set -euo pipefail

# Any model on vLLM, configured only through environment variables.
#
# Use this for a new model instead of writing a new target script: set MODEL, SERVED_MODEL_NAME, PORT and the GPUs,
# and put model-specific flags (reasoning or tool parsers, --language-model-only, ...) in EXTRA_ARGS.
# The web panel (control/) writes these values per instance. Empty values leave vLLM's own default.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/preflight.sh
source "$REPO_ROOT/lib/preflight.sh"

# HuggingFace ID (downloaded on first start) or a local directory.
MODEL="${MODEL:-}"
# Name clients put in the "model" field. Defaults to the last part of MODEL.
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-}"
# 127.0.0.1 keeps the engine private behind the panel gateway; 0.0.0.0 opens it to the network.
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8000}"
PID_FILE="${PID_FILE:-$REPO_ROOT/vllm-serve-$PORT.pid}"
# GPU indexes for this server, comma separated (see nvidia-smi -L).
export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0,1}"
# Tensor parallel size. Empty = number of GPUs in CUDA_VISIBLE_DEVICES.
TP_SIZE="${TP_SIZE:-}"
# Context length in tokens. Empty = the model's own maximum (often too large for 24 GB cards).
MAX_MODEL_LEN="${MAX_MODEL_LEN:-32768}"
# Share of each GPU's memory vLLM may take (weights + KV cache).
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.90}"
# Concurrent sequences. Empty = vLLM default.
MAX_NUM_SEQS="${MAX_NUM_SEQS:-}"
# auto, or fp8 to halve the KV cache.
KV_CACHE_DTYPE="${KV_CACHE_DTYPE:-auto}"
# 1 = cache shared prompt prefixes (good for agents that resend long contexts).
ENABLE_PREFIX_CACHING="${ENABLE_PREFIX_CACHING:-1}"
# 1 = off. Consumer cards have no NVLink and custom all-reduce over PCIe is a known hang source.
DISABLE_CUSTOM_ALL_REDUCE="${DISABLE_CUSTOM_ALL_REDUCE:-1}"
# Reasoning parser name for thinking models (e.g. qwen3, deepseek_r1). Empty = none.
REASONING_PARSER="${REASONING_PARSER:-}"
# Tool call parser (e.g. qwen3_coder, hermes). Setting it also turns on automatic tool choice.
TOOL_CALL_PARSER="${TOOL_CALL_PARSER:-}"
# 1 = allow model code from the repository (only for models you trust).
TRUST_REMOTE_CODE="${TRUST_REMOTE_CODE:-0}"
# Any further vLLM flags, separated by spaces (e.g. --language-model-only --max-num-batched-tokens 8192).
EXTRA_ARGS="${EXTRA_ARGS:-}"
# vllm executable. An engine environment from envs/install-engine.sh, else PATH, else the repo .venv.
VLLM_BIN="${VLLM_BIN:-}"

if [[ -z "$VLLM_BIN" ]]; then
  if command -v vllm >/dev/null 2>&1; then VLLM_BIN="$(command -v vllm)"; else VLLM_BIN="$REPO_ROOT/.venv/bin/vllm"; fi
fi
IFS=',' read -ra _gpus <<< "$CUDA_VISIBLE_DEVICES"
TP_SIZE="${TP_SIZE:-${#_gpus[@]}}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-$(basename "$MODEL")}"

preflight_executable "$VLLM_BIN" "vllm executable" "Install an engine environment: envs/install-engine.sh vllm <version>, then set VLLM_BIN."
preflight_model "$MODEL"
preflight_gpus
preflight_port "$PORT"
preflight_shm_warning

args=(serve "$MODEL" --served-model-name "$SERVED_MODEL_NAME" --host "$HOST" --port "$PORT"
      --tensor-parallel-size "$TP_SIZE" --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION"
      --kv-cache-dtype "$KV_CACHE_DTYPE")
[[ -n "$MAX_MODEL_LEN" ]] && args+=(--max-model-len "$MAX_MODEL_LEN")
[[ -n "$MAX_NUM_SEQS" ]] && args+=(--max-num-seqs "$MAX_NUM_SEQS")
[[ "$ENABLE_PREFIX_CACHING" == "1" ]] && args+=(--enable-prefix-caching)
[[ "$DISABLE_CUSTOM_ALL_REDUCE" == "1" ]] && args+=(--disable-custom-all-reduce)
[[ -n "$REASONING_PARSER" ]] && args+=(--reasoning-parser "$REASONING_PARSER")
[[ -n "$TOOL_CALL_PARSER" ]] && args+=(--enable-auto-tool-choice --tool-call-parser "$TOOL_CALL_PARSER")
[[ "$TRUST_REMOTE_CODE" == "1" ]] && args+=(--trust-remote-code)
if [[ -n "$EXTRA_ARGS" ]]; then read -ra _extra <<< "$EXTRA_ARGS"; args+=("${_extra[@]}"); fi

echo "Starting vLLM: $VLLM_BIN ${args[*]}"
echo "  cuda devices: $CUDA_VISIBLE_DEVICES"
echo "$$" > "$PID_FILE"
exec "$VLLM_BIN" "${args[@]}" "$@"
