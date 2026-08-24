#!/usr/bin/env bash
set -euo pipefail

# Register the local vLLM server as an OpenCode provider, without changing
# OpenCode's default model:
#   opencode                              -> /models to pick the local model
#   opencode -m vllm/qwen3.6-27b-fp8      -> local model directly
# Existing config (~/.config/opencode/opencode.json) is preserved — only the
# provider entry named by OPENCODE_PROVIDER is (re)written.
# Reads SERVED_MODEL_NAME/PORT from .env; override with OPENCODE_MODEL,
# OPENCODE_BASE_URL, OPENCODE_PROVIDER, or OPENCODE_CONFIG.

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

OPENCODE_MODEL="${OPENCODE_MODEL:-$SERVED_MODEL_NAME}"
OPENCODE_BASE_URL="${OPENCODE_BASE_URL:-http://127.0.0.1:$PORT/v1}"
OPENCODE_PROVIDER="${OPENCODE_PROVIDER:-vllm}"
OPENCODE_CONFIG="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"

if [[ "${ENABLE_TOOL_CALLS:-1}" != "1" ]]; then
  echo "WARNING: ENABLE_TOOL_CALLS is set to 0 in .env." >&2
  echo "         OpenCode requires tool calling; remove that line (default is on) and restart vLLM." >&2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required to safely merge JSON config." >&2
  exit 1
fi

mkdir -p "$(dirname "$OPENCODE_CONFIG")"

if [[ -f "$OPENCODE_CONFIG" ]]; then
  backup="$OPENCODE_CONFIG.backup.$(date +%Y%m%d-%H%M%S)"
  cp "$OPENCODE_CONFIG" "$backup"
  echo "Backed up existing config to $backup"
fi

python3 - "$OPENCODE_CONFIG" "$OPENCODE_PROVIDER" "$OPENCODE_MODEL" "$OPENCODE_BASE_URL" <<'PY'
import json, os, sys

path, provider_key, model, base_url = sys.argv[1:5]

cfg = {}
if os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        text = f.read().strip()
    if text:
        try:
            cfg = json.loads(text)
        except json.JSONDecodeError as e:
            sys.stderr.write(
                f"ERROR: could not parse existing {path}: {e}\n"
                "       Fix the JSON (or move the file away) and rerun — nothing was changed.\n"
            )
            sys.exit(1)

cfg.setdefault("$schema", "https://opencode.ai/config.json")
cfg.setdefault("provider", {})[provider_key] = {
    "npm": "@ai-sdk/openai-compatible",
    "name": f"vLLM local ({model})",
    "options": {"baseURL": base_url},
    "models": {model: {"name": model}},
}

with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY

echo "Wrote provider '$OPENCODE_PROVIDER' into $OPENCODE_CONFIG"
echo "  default model:  unchanged (other config keys preserved)"
echo "  local model:    $OPENCODE_PROVIDER/$OPENCODE_MODEL @ $OPENCODE_BASE_URL"
echo
echo "Usage:"
echo "  opencode                                  # then /models to pick the local model"
echo "  opencode -m $OPENCODE_PROVIDER/$OPENCODE_MODEL   # local model directly"
