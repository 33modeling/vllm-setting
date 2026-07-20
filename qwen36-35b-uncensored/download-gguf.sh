#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi

MODEL_DIR="${MODEL_DIR:-$SCRIPT_DIR/models}"
GGUF_QUANT="${GGUF_QUANT:-Q6_K_P}"
GGUF_REPO="${GGUF_REPO:-HauhauCS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive}"
GGUF_FILE="${GGUF_FILE:-Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-${GGUF_QUANT}.gguf}"
MODEL_PATH="${MODEL_PATH:-$MODEL_DIR/$GGUF_FILE}"
MODEL_URL="https://huggingface.co/${GGUF_REPO}/resolve/main/${GGUF_FILE}?download=true"
DOWNLOAD_MMPROJ="${DOWNLOAD_MMPROJ:-0}"
MMPROJ_FILE="mmproj-Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-f16.gguf"
MMPROJ_PATH="${MMPROJ_PATH:-$MODEL_DIR/$MMPROJ_FILE}"

command -v curl >/dev/null 2>&1 || {
  echo "curl is required." >&2
  exit 1
}

mkdir -p "$MODEL_DIR"

if [[ -s "$MODEL_PATH" ]]; then
  echo "Model already exists: $MODEL_PATH"
else
  echo "Downloading $GGUF_FILE (~31 GB for Q6_K_P) to $MODEL_PATH"
  echo "Q6_K_P is the default for 2x24 GB; smaller options: Q5_K_P (~28 GB), Q4_K_P (~23 GB)."
  curl --fail --location --retry 5 --retry-delay 3 --continue-at - \
    --output "$MODEL_PATH.part" "$MODEL_URL"
  mv "$MODEL_PATH.part" "$MODEL_PATH"
  echo "Downloaded: $MODEL_PATH"
fi

# Vision projector — text-only serving does not need it.
if [[ "$DOWNLOAD_MMPROJ" == "1" && ! -s "$MMPROJ_PATH" ]]; then
  echo "Downloading $MMPROJ_FILE (~0.9 GB) to $MMPROJ_PATH"
  curl --fail --location --retry 5 --retry-delay 3 --continue-at - \
    --output "$MMPROJ_PATH.part" \
    "https://huggingface.co/${GGUF_REPO}/resolve/main/${MMPROJ_FILE}?download=true"
  mv "$MMPROJ_PATH.part" "$MMPROJ_PATH"
  echo "Downloaded: $MMPROJ_PATH"
fi
