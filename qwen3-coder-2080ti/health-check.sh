#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

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

BACKEND="${BACKEND:-llama}"
HOST="${HOST:-127.0.0.1}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-qwen3-coder-30b-a3b}"
WAIT_READY_SECONDS="${WAIT_READY_SECONDS:-600}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-180}"

case "$BACKEND" in
  llama) PORT="${LLAMA_PORT:-8080}" ;;
  vllm) PORT="${VLLM_PORT:-8000}" ;;
  *) echo "BACKEND must be llama or vllm." >&2; exit 1 ;;
esac

if [[ "$HOST" == "0.0.0.0" || "$HOST" == "::" ]]; then
  CLIENT_HOST=127.0.0.1
else
  CLIENT_HOST="$HOST"
fi

BASE_URL="${BASE_URL:-http://$CLIENT_HOST:$PORT/v1}"
models_response="$(mktemp)"
chat_response="$(mktemp)"
trap 'rm -f "$models_response" "$chat_response"' EXIT
deadline=$((SECONDS + WAIT_READY_SECONDS))

echo "Checking $BACKEND at $BASE_URL"
until curl -fsS --max-time "$REQUEST_TIMEOUT" "$BASE_URL/models" > "$models_response"; do
  if (( SECONDS >= deadline )); then
    echo "Server did not become ready within ${WAIT_READY_SECONDS}s." >&2
    exit 1
  fi
  sleep 2
done

curl -fsS --max-time "$REQUEST_TIMEOUT" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"$SERVED_MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: OK\"}],\"temperature\":0,\"max_tokens\":16}" \
  "$BASE_URL/chat/completions" > "$chat_response"

echo "models endpoint OK"
echo "chat completion OK"
if command -v jq >/dev/null 2>&1; then
  jq -r '.choices[0].message.content // empty' "$chat_response"
fi
