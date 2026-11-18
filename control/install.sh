#!/usr/bin/env bash
set -euo pipefail

# Install the web panel as a systemd user service (llmctl.service) on the GPU server. Safe to run again after a
# git pull: it refreshes the panel's own uv environment and the unit, and keeps config.yaml and instances/.

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

if ! command -v uv >/dev/null 2>&1; then
  echo "ERROR: uv is not installed. Install it with: curl -LsSf https://astral.sh/uv/install.sh | sh" >&2
  exit 1
fi

# The panel package is not installed into .venv; it is imported from this folder, so every python call below
# runs with PYTHONPATH=$DIR (install.sh may be called from any directory).
py() { PYTHONPATH="$DIR${PYTHONPATH:+:$PYTHONPATH}" "$DIR/.venv/bin/python" "$@"; }

echo "== panel environment (control/.venv)"
(cd "$DIR" && uv sync --frozen --no-dev -q)

echo "== settings"
py -c "from llmctl import settings; c = settings.load(); print('  config:', c.path)"
if ! compgen -G "$DIR/instances/*.yaml" >/dev/null; then
  cp "$DIR"/examples/*.yaml "$DIR/instances/"
  echo "  copied example instances into control/instances/ (edit or delete them in the panel)"
fi

echo "== systemd user service"
mkdir -p "$UNIT_DIR"
cat > "$UNIT_DIR/llmctl.service" <<UNIT
[Unit]
Description=llmctl web panel for vllm-setting
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$DIR
Environment=PATH=$PATH
Environment=PYTHONUNBUFFERED=1
ExecStart=$DIR/.venv/bin/python -m llmctl
Restart=on-failure
RestartSec=5
# Models run in their own units (or process groups); restarting the panel must not take them down.
KillMode=process

[Install]
WantedBy=default.target
UNIT
systemctl --user daemon-reload
systemctl --user enable --now llmctl.service
systemctl --user restart llmctl.service

if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || true)" != "yes" ]]; then
  if loginctl enable-linger "$USER" 2>/dev/null; then
    echo "  linger on: the panel and models keep running after you log out and start after a reboot"
  else
    echo "  NOTE: run 'sudo loginctl enable-linger $USER' once so the panel keeps running after logout and reboot"
  fi
fi

port="$(py -c "from llmctl import settings; print(settings.load().port)")"
token="$(py -c "from llmctl import settings; print(settings.load().token)")"
cat <<EOF

Panel:    http://$(hostname -I 2>/dev/null | awk '{print $1}'):$port/#token=$token   (logs this browser in once)
Token:    $token     (also in $DIR/config.yaml)
Gateway:  http://127.0.0.1:$port/v1   (OpenAI-compatible; routes by model name)
Terminal: $DIR/llmctl.sh status
EOF
