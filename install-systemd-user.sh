#!/usr/bin/env bash
set -euo pipefail

# Install a user-level systemd service for this checkout.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="${SERVICE_NAME:-vllm-qwen36.service}"
SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SERVICE_PATH="$SYSTEMD_USER_DIR/$SERVICE_NAME"
TEMPLATE="$SCRIPT_DIR/systemd/vllm-qwen36.service.in"

if ! command -v systemctl >/dev/null 2>&1; then
  echo "systemctl is required." >&2
  exit 1
fi

if [[ ! -f "$TEMPLATE" ]]; then
  echo "Missing template: $TEMPLATE" >&2
  exit 1
fi

mkdir -p "$SYSTEMD_USER_DIR"
escaped_dir="${SCRIPT_DIR//\\/\\\\}"
escaped_dir="${escaped_dir//&/\\&}"
sed "s|__WORKDIR__|$escaped_dir|g" "$TEMPLATE" > "$SERVICE_PATH"

systemctl --user daemon-reload
systemctl --user enable "$SERVICE_NAME"

cat <<EOF
Installed $SERVICE_PATH

Start:
  systemctl --user start $SERVICE_NAME

Stop:
  systemctl --user stop $SERVICE_NAME

Restart:
  systemctl --user restart $SERVICE_NAME

Logs:
  journalctl --user -u $SERVICE_NAME -f
EOF

if [[ "${START_NOW:-0}" == "1" ]]; then
  systemctl --user restart "$SERVICE_NAME"
fi
