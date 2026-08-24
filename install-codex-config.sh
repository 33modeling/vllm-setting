#!/usr/bin/env bash
set -euo pipefail

# Register the local vLLM server as a Codex profile, without changing Codex's
# default model:
#   codex                        -> original default model (unchanged)
#   codex --profile qwen-local   -> local vLLM server
#
# Recent Codex versions no longer allow [profiles.*] sections inside
# config.toml — each profile lives in its own overlay file at
# $CODEX_HOME/<name>.config.toml. This script writes that file and does NOT
# touch config.toml, except to remove blocks that older versions of this
# script wrote there (which now break Codex startup).
#
# Reads SERVED_MODEL_NAME/PORT from .env; override with CODEX_MODEL,
# CODEX_BASE_URL, CODEX_PROFILE, or CODEX_HOME.

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

SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-qwen3.6-27b-fp8}"
PORT="${PORT:-8000}"

CODEX_MODEL="${CODEX_MODEL:-$SERVED_MODEL_NAME}"
CODEX_BASE_URL="${CODEX_BASE_URL:-http://127.0.0.1:$PORT/v1}"
CODEX_PROFILE="${CODEX_PROFILE:-qwen-local}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CONFIG_PATH="$CODEX_HOME/config.toml"
PROFILE_PATH="$CODEX_HOME/$CODEX_PROFILE.config.toml"

MARK_BEGIN="# --- vllm-setting managed block (installed by install-codex-config.sh) ---"
MARK_END="# --- end vllm-setting managed block ---"

if [[ "${ENABLE_TOOL_CALLS:-1}" != "1" ]]; then
  echo "WARNING: ENABLE_TOOL_CALLS is set to 0 in .env." >&2
  echo "         Codex requires tool calling; remove that line (default is on) and restart vLLM." >&2
fi

mkdir -p "$CODEX_HOME"

# --- Migration: remove what older script versions wrote into config.toml ----
if [[ -f "$CONFIG_PATH" ]] && grep -Eq \
    '^# --- vllm-setting managed block|^\[model_providers\.vllm\]|^\[profiles\.' \
    "$CONFIG_PATH"; then
  backup="$CONFIG_PATH.backup.$(date +%Y%m%d-%H%M%S)"
  cp "$CONFIG_PATH" "$backup"
  echo "Backed up config.toml to $backup"

  cleaned="$(awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    $0 == b {skip=1; next}
    $0 == e {skip=0; next}
    !skip {print}
  ' "$CONFIG_PATH")"

  # Drop unmarked sections we own and our profile section (now illegal in
  # config.toml on recent Codex versions).
  cleaned="$(printf '%s\n' "$cleaned" | awk -v prof="[profiles.$CODEX_PROFILE]" '
    {
      if (drop && $0 ~ /^\[/) drop=0
      if ($0 == "[model_providers.vllm]" || $0 == prof) drop=1
      if (!drop) print
    }
  ')"

  # Drop the top-level default that the oldest script version forced.
  if printf '%s\n' "$cleaned" | awk 'BEGIN{top=1} /^\[/{top=0} top' \
      | grep -Eq '^model_provider *= *"vllm"'; then
    cleaned="$(printf '%s\n' "$cleaned" | awk '
      BEGIN{top=1}
      /^\[/{top=0}
      top && /^model *=/ {next}
      top && /^model_provider *=/ {next}
      {print}
    ')"
  fi

  printf '%s\n' "$cleaned" > "$CONFIG_PATH"
  echo "Removed vllm-setting blocks from config.toml (profiles now live in their own file)."
fi

# --- Write the profile overlay file ----------------------------------------
if [[ -f "$PROFILE_PATH" ]]; then
  backup="$PROFILE_PATH.backup.$(date +%Y%m%d-%H%M%S)"
  cp "$PROFILE_PATH" "$backup"
  echo "Backed up existing profile to $backup"
fi

cat > "$PROFILE_PATH" <<EOF
# Managed by vllm-setting/install-codex-config.sh — rerun it to regenerate.
model = "$CODEX_MODEL"
model_provider = "vllm"

[model_providers.vllm]
name = "vLLM local ($CODEX_MODEL)"
base_url = "$CODEX_BASE_URL"
# Codex >= 0.132 dropped wire_api = "chat"; the vLLM server must expose
# /v1/responses (recent vLLM versions do).
wire_api = "responses"
EOF

echo "Wrote $PROFILE_PATH"
echo "  default model:  unchanged (Codex original; config.toml not modified)"
echo "  local profile:  $CODEX_PROFILE -> $CODEX_MODEL @ $CODEX_BASE_URL"
echo
echo "Usage:"
echo "  codex                            # original default model"
echo "  codex --profile $CODEX_PROFILE   # local vLLM model"
