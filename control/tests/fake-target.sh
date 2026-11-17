#!/usr/bin/env bash
set -euo pipefail
# Fake target for the control panel tests: serves a stand-in engine instead of vLLM.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Model to serve (the fake engine only reports it).
MODEL="${MODEL:-Qwen/Qwen3.8-27B-FP8}"
# Name the engine answers to.
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-fake-model}"
HOST="${HOST:-127.0.0.1}"
# API port.
PORT="${PORT:-18000}"
export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"
PID_FILE="${PID_FILE:-$SCRIPT_DIR/fake.pid}"
# Exit with this code before starting (simulates a failed preflight check).
FAIL_PREFLIGHT="${FAIL_PREFLIGHT:-0}"
if [[ "$FAIL_PREFLIGHT" != "0" ]]; then
  echo "ERROR: preflight failed on purpose" >&2
  exit "$FAIL_PREFLIGHT"
fi
echo "$$" > "$PID_FILE"
exec python3 "$SCRIPT_DIR/fake_engine.py" "$PORT" "$SERVED_MODEL_NAME"
