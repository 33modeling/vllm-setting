#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-$SCRIPT_DIR/llama.cpp}"
BUILD_DIR="${BUILD_DIR:-$LLAMA_CPP_DIR/build}"
CUDA_ARCHITECTURES="${CUDA_ARCHITECTURES:-89}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"

for command_name in git cmake; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required." >&2
    exit 1
  fi
done

if ! command -v nvcc >/dev/null 2>&1; then
  echo "nvcc is required. Install a CUDA toolkit supported by the NVIDIA driver." >&2
  exit 1
fi

if [[ -d "$LLAMA_CPP_DIR/.git" ]]; then
  git -C "$LLAMA_CPP_DIR" fetch origin
  git -C "$LLAMA_CPP_DIR" pull --ff-only
elif [[ -e "$LLAMA_CPP_DIR" ]]; then
  echo "$LLAMA_CPP_DIR exists but is not a git checkout." >&2
  exit 1
else
  git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$LLAMA_CPP_DIR"
fi

cmake -S "$LLAMA_CPP_DIR" -B "$BUILD_DIR" \
  -DGGML_CUDA=ON \
  -DLLAMA_CURL=ON \
  -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCHITECTURES" \
  -DCMAKE_BUILD_TYPE=Release

cmake --build "$BUILD_DIR" --config Release --target llama-server llama-cli -j "$BUILD_JOBS"

cat <<EOF
llama.cpp installed:
  $BUILD_DIR/bin/llama-server
  $BUILD_DIR/bin/llama-cli
EOF
