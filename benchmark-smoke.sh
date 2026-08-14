#!/usr/bin/env bash
set -euo pipefail

# Small coding-oriented smoke benchmark for comparing local vLLM settings.

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
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-180}"
MAX_TOKENS="${BENCH_MAX_TOKENS:-512}"

if [[ "$HOST" == "0.0.0.0" || "$HOST" == "::" ]]; then
  CLIENT_HOST="127.0.0.1"
else
  CLIENT_HOST="$HOST"
fi

BASE_URL="${BASE_URL:-http://$CLIENT_HOST:$PORT/v1}"

print_gpu() {
  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=index,name,memory.used,memory.total --format=csv,noheader
  fi
}

extract_number() {
  local key="$1"
  local file="$2"
  grep -o "\"$key\"[[:space:]]*:[[:space:]]*[0-9]*" "$file" \
    | head -n 1 \
    | grep -o '[0-9]*$' || true
}

run_case() {
  local name="$1"
  local prompt="$2"
  local body
  local response
  local start_ms
  local end_ms
  local elapsed_ms
  local completion_tokens
  local total_tokens
  local tps

  body="$(mktemp)"
  response="$(mktemp)"

  cat > "$body" <<EOF
{
  "model": "$SERVED_MODEL_NAME",
  "messages": [
    {"role": "user", "content": "$prompt"}
  ],
  "temperature": 0.2,
  "top_p": 0.95,
  "max_tokens": $MAX_TOKENS
}
EOF

  start_ms="$(date +%s%3N)"
  if ! curl -fsS \
    --max-time "$REQUEST_TIMEOUT" \
    -H "Content-Type: application/json" \
    -d @"$body" \
    "$BASE_URL/chat/completions" > "$response"; then
    echo "$name: failed"
    rm -f "$body" "$response"
    return 1
  fi
  end_ms="$(date +%s%3N)"
  elapsed_ms=$((end_ms - start_ms))

  completion_tokens="$(extract_number completion_tokens "$response")"
  total_tokens="$(extract_number total_tokens "$response")"

  if [[ -n "$completion_tokens" && "$completion_tokens" != "0" ]]; then
    tps="$(awk "BEGIN { printf \"%.2f\", $completion_tokens / ($elapsed_ms / 1000) }")"
  else
    tps="n/a"
  fi

  printf '%-18s elapsed=%6sms completion_tokens=%-5s total_tokens=%-5s tok/s=%s\n' \
    "$name" "$elapsed_ms" "${completion_tokens:-n/a}" "${total_tokens:-n/a}" "$tps"

  rm -f "$body" "$response"
}

echo "Benchmark endpoint: $BASE_URL"
echo "Model: $SERVED_MODEL_NAME"
echo
echo "GPU before:"
print_gpu || true
echo

run_case "binary-search" "Write a Python function for binary search with type hints."
run_case "bug-review" "Review this Python snippet for bugs: def f(xs): return xs[0] if len(xs) >= 0 else None"
run_case "lru-cache" "Implement a small LRU cache class in Python using OrderedDict."

echo
echo "GPU after:"
print_gpu || true
