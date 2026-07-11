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

TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-30}"
found=0

for pid_file in \
  "${LLAMA_PID_FILE:-$SCRIPT_DIR/llama-server.pid}" \
  "${VLLM_PID_FILE:-$SCRIPT_DIR/vllm-server.pid}"; do
  [[ -f "$pid_file" ]] || continue
  pid="$(tr -dc '0-9' < "$pid_file")"

  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    found=1
    echo "Stopping PID $pid from $pid_file"
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true

    deadline=$((SECONDS + TIMEOUT_SECONDS))
    while kill -0 "$pid" 2>/dev/null && (( SECONDS < deadline )); do
      sleep 1
    done

    if kill -0 "$pid" 2>/dev/null; then
      echo "PID $pid did not exit; sending SIGKILL."
      kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    fi
  fi

  rm -f "$pid_file"
done

if [[ "$found" == "0" ]]; then
  echo "No managed Qwen3-Coder server found."
else
  echo "Server stopped."
fi
