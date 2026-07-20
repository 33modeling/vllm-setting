#!/usr/bin/env bash
set -euo pipefail

# Register the local vLLM server in ~/.codex/config.toml as a *selectable*
# option, without changing Codex's default model:
#   codex                        -> original default model (unchanged)
#   codex --profile qwen-local   -> local vLLM server
# Existing config content is preserved; only a marked managed block is
# (re)written. A previous version of this script forced the local model as
# the top-level default — that override is removed if found.
# Reads SERVED_MODEL_NAME/PORT from .env; override with CODEX_MODEL,
# CODEX_BASE_URL, CODEX_PROFILE, or CODEX_HOME.

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
CODEX_PROFILE="${CODEX_PROFILE:-qwen-local}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CONFIG_PATH="$CODEX_HOME/config.toml"

MARK_BEGIN="# --- vllm-setting managed block (installed by install-codex-config.sh) ---"
MARK_END="# --- end vllm-setting managed block ---"

if [[ "${ENABLE_TOOL_CALLS:-1}" != "1" ]]; then
  echo "WARNING: ENABLE_TOOL_CALLS is set to 0 in .env." >&2
  echo "         Codex requires tool calling; remove that line (default is on) and restart vLLM." >&2
fi

mkdir -p "$CODEX_HOME"

base=""
if [[ -f "$CONFIG_PATH" ]]; then
  backup="$CONFIG_PATH.backup.$(date +%Y%m%d-%H%M%S)"
  cp "$CONFIG_PATH" "$backup"
  echo "Backed up existing config.toml to $backup"

  # Drop a previous managed block, keep everything else.
  base="$(awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    $0 == b {skip=1; next}
    $0 == e {skip=0; next}
    !skip {print}
  ' "$CONFIG_PATH")"

  # Also drop unmarked sections we own (written by older script versions
  # before the managed-block markers existed).
  base="$(printf '%s\n' "$base" | awk -v prof="[profiles.$CODEX_PROFILE]" '
    {
      if (drop && $0 ~ /^\[/) drop=0
      if ($0 == "[model_providers.vllm]" || $0 == prof) drop=1
      if (!drop) print
    }
  ')"

  # An earlier version of this script wrote a top-level default pointing at
  # the vllm provider. Remove that override (and only that) so Codex falls
  # back to its original default model.
  if printf '%s\n' "$base" | awk 'BEGIN{top=1} /^\[/{top=0} top' \
      | grep -Eq '^model_provider *= *"vllm"'; then
    base="$(printf '%s\n' "$base" | awk '
      BEGIN{top=1}
      /^\[/{top=0}
      top && /^model *=/ {next}
      top && /^model_provider *=/ {next}
      {print}
    ')"
    echo "Removed old top-level default (model/model_provider) written by a previous version."
  fi
fi

{
  if [[ -n "$base" ]]; then
    printf '%s\n\n' "$base"
  fi
  cat <<EOF
$MARK_BEGIN
[model_providers.vllm]
name = "vLLM local ($CODEX_MODEL)"
base_url = "$CODEX_BASE_URL"
# Codex >= 0.132 dropped wire_api = "chat"; requires the Responses API.
# The vLLM server must expose /v1/responses (recent vLLM versions do).
wire_api = "responses"

[profiles.$CODEX_PROFILE]
model = "$CODEX_MODEL"
model_provider = "vllm"
$MARK_END
EOF
} > "$CONFIG_PATH"

echo "Wrote $CONFIG_PATH"
echo "  default model:  unchanged (Codex original)"
echo "  local profile:  $CODEX_PROFILE -> $CODEX_MODEL @ $CODEX_BASE_URL"
echo
echo "Usage:"
echo "  codex                            # original default model"
echo "  codex --profile $CODEX_PROFILE   # local vLLM model"
