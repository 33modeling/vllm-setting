#!/usr/bin/env bash
set -euo pipefail

# Check that vLLM is reachable and can answer a small chat request.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/.env"
  set +a
fi

command -v curl >/dev/null 2>&1 || {
  echo "curl is required." >&2
  exit 1
}

HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8000}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-qwen3.6-27b-fp8}"
WAIT_READY_SECONDS="${WAIT_READY_SECONDS:-300}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-120}"
CHAT_CHECK="${CHAT_CHECK:-1}"

if [[ "$HOST" == "0.0.0.0" || "$HOST" == "::" ]]; then
  CLIENT_HOST="127.0.0.1"
else
  CLIENT_HOST="$HOST"
fi

BASE_URL="${BASE_URL:-http://$CLIENT_HOST:$PORT/v1}"
deadline=$((SECONDS + WAIT_READY_SECONDS))
models_response="$(mktemp)"
chat_body="$(mktemp)"
chat_response="$(mktemp)"
trap 'rm -f "$models_response" "$chat_body" "$chat_response"' EXIT

echo "Checking vLLM at $BASE_URL"

while true; do
  if curl -fsS --max-time "$REQUEST_TIMEOUT" "$BASE_URL/models" > "$models_response"; then
    echo "models endpoint OK"
    break
  fi

  if (( SECONDS >= deadline )); then
    echo "vLLM did not become ready within ${WAIT_READY_SECONDS}s." >&2
    exit 1
  fi

  sleep 2
done

if [[ "$CHAT_CHECK" != "1" ]]; then
  exit 0
fi

cat > "$chat_body" <<EOF
{
  "model": "$SERVED_MODEL_NAME",
  "messages": [
    {"role": "user", "content": "Reply with exactly: OK"}
  ],
  "temperature": 0,
  "max_tokens": 16
}
EOF

if curl -fsS \
  --max-time "$REQUEST_TIMEOUT" \
  -H "Content-Type: application/json" \
  -d @"$chat_body" \
  "$BASE_URL/chat/completions" > "$chat_response"; then
  echo "chat completion OK"
  if command -v jq >/dev/null 2>&1; then
    jq -r '.choices[0].message.content // empty' "$chat_response"
  fi
else
  echo "chat completion failed." >&2
  cat "$chat_response" >&2 || true
  exit 1
fi
