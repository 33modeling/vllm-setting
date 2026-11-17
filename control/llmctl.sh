#!/usr/bin/env bash
# Terminal client: control/llmctl.sh status | start NAME | stop NAME | restart NAME | logs NAME [-f]
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec "$DIR/.venv/bin/python" -m llmctl.cli "$@"
