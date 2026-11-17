#!/usr/bin/env bash
set -euo pipefail

# Any model on SGLang, configured only through environment variables.
#
# Same idea as targets/vllm-serve.sh: one script for every model, model-specific flags in EXTRA_ARGS.
# SGLang serves the same OpenAI-compatible /v1 API, so clients and the panel gateway treat it like vLLM.

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
PORT="${PORT:-30000}"
PID_FILE="${PID_FILE:-$REPO_ROOT/sglang-serve-$PORT.pid}"
# GPU indexes for this server, comma separated (see nvidia-smi -L).
export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0,1}"
# Tensor parallel size. Empty = number of GPUs in CUDA_VISIBLE_DEVICES.
TP_SIZE="${TP_SIZE:-}"
# Context length in tokens. Empty = the model's own maximum.
CONTEXT_LENGTH="${CONTEXT_LENGTH:-32768}"
# Share of GPU memory for weights + KV cache (SGLang --mem-fraction-static). Lower it if startup runs out of memory.
MEM_FRACTION_STATIC="${MEM_FRACTION_STATIC:-0.85}"
# Reasoning parser for thinking models (e.g. qwen3, deepseek-r1). Empty = none.
REASONING_PARSER="${REASONING_PARSER:-}"
# Tool call parser (e.g. qwen25, qwen3_coder). Empty = none.
TOOL_CALL_PARSER="${TOOL_CALL_PARSER:-}"
# 1 = allow model code from the repository (only for models you trust).
TRUST_REMOTE_CODE="${TRUST_REMOTE_CODE:-0}"
# Any further SGLang flags, separated by spaces (e.g. --kv-cache-dtype fp8_e5m2 --chunked-prefill-size 4096).
EXTRA_ARGS="${EXTRA_ARGS:-}"
# python of the SGLang environment (envs/install-engine.sh sglang <version> prints it), else python3 on PATH.
SGLANG_PYTHON="${SGLANG_PYTHON:-python3}"

IFS=',' read -ra _gpus <<< "$CUDA_VISIBLE_DEVICES"
TP_SIZE="${TP_SIZE:-${#_gpus[@]}}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-$(basename "$MODEL")}"

preflight_executable "$SGLANG_PYTHON" "SGLang python" "Install an engine environment: envs/install-engine.sh sglang <version>, then set SGLANG_PYTHON."
if ! "$SGLANG_PYTHON" -c "import sglang" >/dev/null 2>&1; then
  echo "ERROR: '$SGLANG_PYTHON' cannot import sglang. Point SGLANG_PYTHON at the python of an SGLang environment." >&2
  exit 1
fi
preflight_model "$MODEL"
preflight_gpus
preflight_port "$PORT"
preflight_shm_warning

args=(-m sglang.launch_server --model-path "$MODEL" --served-model-name "$SERVED_MODEL_NAME" --host "$HOST"
      --port "$PORT" --tp-size "$TP_SIZE" --mem-fraction-static "$MEM_FRACTION_STATIC")
[[ -n "$CONTEXT_LENGTH" ]] && args+=(--context-length "$CONTEXT_LENGTH")
[[ -n "$REASONING_PARSER" ]] && args+=(--reasoning-parser "$REASONING_PARSER")
[[ -n "$TOOL_CALL_PARSER" ]] && args+=(--tool-call-parser "$TOOL_CALL_PARSER")
[[ "$TRUST_REMOTE_CODE" == "1" ]] && args+=(--trust-remote-code)
if [[ -n "$EXTRA_ARGS" ]]; then read -ra _extra <<< "$EXTRA_ARGS"; args+=("${_extra[@]}"); fi

echo "Starting SGLang: $SGLANG_PYTHON ${args[*]}"
echo "  cuda devices: $CUDA_VISIBLE_DEVICES"
echo "$$" > "$PID_FILE"
exec "$SGLANG_PYTHON" "${args[@]}" "$@"
