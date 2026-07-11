#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODEL_DIR="${MODEL_DIR:-$SCRIPT_DIR/models}"
GGUF_QUANT="${GGUF_QUANT:-Q4_K_S}"
GGUF_FILE="${GGUF_FILE:-Qwen3-Coder-30B-A3B-Instruct-${GGUF_QUANT}.gguf}"
GGUF_REPO="${GGUF_REPO:-unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF}"
MODEL_PATH="${MODEL_PATH:-$MODEL_DIR/$GGUF_FILE}"
MODEL_URL="https://huggingface.co/${GGUF_REPO}/resolve/main/${GGUF_FILE}?download=true"

command -v curl >/dev/null 2>&1 || {
  echo "curl is required." >&2
  exit 1
}

mkdir -p "$MODEL_DIR"

if [[ -s "$MODEL_PATH" ]]; then
  echo "Model already exists: $MODEL_PATH"
  exit 0
fi

echo "Downloading $GGUF_FILE to $MODEL_PATH"
echo "Q4_K_S is the safe default for 2x11 GB; set GGUF_QUANT=Q4_K_M for higher quality and less context headroom."
curl --fail --location --retry 5 --retry-delay 3 --continue-at - \
  --output "$MODEL_PATH.part" "$MODEL_URL"
mv "$MODEL_PATH.part" "$MODEL_PATH"
echo "Downloaded: $MODEL_PATH"
