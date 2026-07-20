#!/usr/bin/env bash
set -euo pipefail

# Write ~/.codex/config.toml so Codex CLI uses the local vLLM server.
# Reads SERVED_MODEL_NAME/PORT from .env; override with CODEX_MODEL,
# CODEX_BASE_URL, or CODEX_HOME.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/.env"
  set +a
fi

SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-qwen3.6-27b}"
PORT="${PORT:-8000}"

CODEX_MODEL="${CODEX_MODEL:-$SERVED_MODEL_NAME}"
CODEX_BASE_URL="${CODEX_BASE_URL:-http://127.0.0.1:$PORT/v1}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CONFIG_PATH="$CODEX_HOME/config.toml"

if [[ "${ENABLE_TOOL_CALLS:-1}" != "1" ]]; then
  echo "WARNING: ENABLE_TOOL_CALLS is set to 0 in .env." >&2
  echo "         Codex requires tool calling; remove that line (default is on) and restart vLLM." >&2
fi

mkdir -p "$CODEX_HOME"

if [[ -f "$CONFIG_PATH" ]]; then
  backup="$CONFIG_PATH.backup.$(date +%Y%m%d-%H%M%S)"
  cp "$CONFIG_PATH" "$backup"
  echo "Backed up existing config.toml to $backup"
fi

cat > "$CONFIG_PATH" <<EOF
model = "$CODEX_MODEL"
model_provider = "vllm"

[model_providers.vllm]
name = "vLLM local ($CODEX_MODEL)"
base_url = "$CODEX_BASE_URL"
wire_api = "chat"
EOF

echo "Wrote $CONFIG_PATH"
echo "  model:    $CODEX_MODEL"
echo "  base_url: $CODEX_BASE_URL"
echo "Run 'codex' to use the local vLLM server."
