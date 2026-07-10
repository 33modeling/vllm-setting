#!/usr/bin/env bash
set -euo pipefail

# Copy one of profiles/*.env to .env.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<EOF
Usage: $0 <profile>

Available profiles:
EOF
  find "$SCRIPT_DIR/profiles" -maxdepth 1 -type f -name '*.env' -printf '  %f\n' \
    | sed 's/\.env$//' \
    | sort
}

if [[ "${1:-}" == "" || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

PROFILE="$1"
PROFILE_PATH="$SCRIPT_DIR/profiles/$PROFILE.env"

if [[ ! -f "$PROFILE_PATH" ]]; then
  echo "Unknown profile: $PROFILE" >&2
  usage >&2
  exit 1
fi

if [[ -f "$SCRIPT_DIR/.env" ]]; then
  backup="$SCRIPT_DIR/.env.backup.$(date +%Y%m%d-%H%M%S)"
  cp "$SCRIPT_DIR/.env" "$backup"
  echo "Backed up existing .env to $backup"
fi

cp "$PROFILE_PATH" "$SCRIPT_DIR/.env"
chmod 600 "$SCRIPT_DIR/.env"
echo "Activated profile '$PROFILE' -> $SCRIPT_DIR/.env"
