#!/usr/bin/env bash
set -euo pipefail

# Stop the vLLM server started by any targets/*.sh script and release GPU memory.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/.env" ]]; then
  # An inherited value (e.g. `PORT=9999 ./health-check.sh`) must win over the
  # config file, whose plain `VAR=value` lines would otherwise clobber it.
  # Snapshot the environment and restore it after sourcing, so the order is
  # command line > config file > built-in default.
  mapfile -d '' -t _preset_env < <(env -0)
  set -a
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/.env"
  set +a
  for _kv in "${_preset_env[@]}"; do
    [[ "$_kv" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    case "${_kv%%=*}" in SHELLOPTS|BASHOPTS|PWD|OLDPWD) continue ;; esac
    export "$_kv"
  done
  unset _preset_env _kv
fi

PORT="${PORT:-8000}"
PID_FILE="${PID_FILE:-$SCRIPT_DIR/vllm.pid}"
MODEL="${MODEL:-Qwen/Qwen3.6-27B-FP8}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-qwen3.6-27b-fp8}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-30}"

pids=()

add_pid() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  [[ "$pid" != "$$" ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0

  local existing
  for existing in "${pids[@]}"; do
    [[ "$existing" == "$pid" ]] && return 0
  done
  pids+=("$pid")
}

collect_descendants() {
  local parent="$1"
  local child

  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    collect_descendants "$child"
    add_pid "$child"
  done < <(pgrep -P "$parent" 2>/dev/null || true)
}

if [[ -f "$PID_FILE" ]]; then
  pid_from_file="$(tr -dc '0-9' < "$PID_FILE" || true)"
  if [[ -n "$pid_from_file" ]] && kill -0 "$pid_from_file" 2>/dev/null; then
    cmd="$(ps -p "$pid_from_file" -o args= 2>/dev/null || true)"
    if [[ "$cmd" == *"vllm"* || "$cmd" == *"$MODEL"* || "$cmd" == *"$SERVED_MODEL_NAME"* ]]; then
      add_pid "$pid_from_file"
    fi
  fi
fi

if command -v ss >/dev/null 2>&1; then
  while IFS= read -r pid_from_port; do
    add_pid "$pid_from_port"
  done < <(ss -H -ltnp "sport = :$PORT" 2>/dev/null | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' || true)
fi

while read -r pid cmd; do
  [[ "$pid" =~ ^[0-9]+$ ]] || continue

  if [[ "$cmd" == *"vllm"* && "$cmd" == *"serve"* ]]; then
    if [[ "$cmd" == *"$PORT"* || "$cmd" == *"$MODEL"* || "$cmd" == *"$SERVED_MODEL_NAME"* ]]; then
      add_pid "$pid"
    fi
  fi
done < <(ps -eo pid=,args= 2>/dev/null || true)

for pid in "${pids[@]}"; do
  collect_descendants "$pid"
done

if [[ "${#pids[@]}" -eq 0 ]]; then
  echo "No matching vLLM process found."
  rm -f "$PID_FILE"
  exit 0
fi

echo "Stopping vLLM process tree: ${pids[*]}"
kill -TERM "${pids[@]}" 2>/dev/null || true

deadline=$((SECONDS + TIMEOUT_SECONDS))
alive=()
while (( SECONDS < deadline )); do
  alive=()
  for pid in "${pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      alive+=("$pid")
    fi
  done

  if [[ "${#alive[@]}" -eq 0 ]]; then
    rm -f "$PID_FILE"
    echo "vLLM stopped."
    exit 0
  fi

  sleep 1
done

echo "Some vLLM processes did not exit after ${TIMEOUT_SECONDS}s; sending SIGKILL: ${alive[*]}"
kill -KILL "${alive[@]}" 2>/dev/null || true
rm -f "$PID_FILE"
sleep 1
echo "vLLM stopped."
