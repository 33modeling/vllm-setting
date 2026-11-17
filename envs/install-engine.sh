#!/usr/bin/env bash
set -euo pipefail

# Install one engine version into its own uv environment, next to the others:
#   envs/install-engine.sh vllm 0.17.1      -> $LLM_ENVS/vllm-0.17.1/bin/vllm
#   envs/install-engine.sh sglang 0.5.6     -> $LLM_ENVS/sglang-0.5.6/bin/python
#   envs/install-engine.sh vllm latest      -> named after the version that got installed
# An existing environment is never modified; install a new version beside it and switch the instance to it.
# lock.txt records every installed package so the same environment can be rebuilt on another server
# (uv pip install --python <env>/bin/python -r lock.txt).

ENGINE="${1:-}"
VERSION="${2:-}"
LLM_ENVS="${LLM_ENVS:-$HOME/.local/share/llm-envs}"
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"

if [[ "$ENGINE" != "vllm" && "$ENGINE" != "sglang" ]] || [[ -z "$VERSION" ]]; then
  echo "usage: $0 vllm|sglang <version|latest>" >&2
  exit 2
fi
if ! command -v uv >/dev/null 2>&1; then
  echo "ERROR: uv is not installed. Install it with: curl -LsSf https://astral.sh/uv/install.sh | sh" >&2
  exit 1
fi

mkdir -p "$LLM_ENVS"
name="$ENGINE-$VERSION"
target="$LLM_ENVS/$name"
if [[ -e "$target" ]]; then
  echo "ERROR: $target already exists. Environments are not changed in place; remove it first to reinstall." >&2
  exit 1
fi
work="$LLM_ENVS/.installing-$name-$$"
trap 'rm -rf "$work"' EXIT

case "$ENGINE" in
  vllm)   spec="vllm"; [[ "$VERSION" != "latest" ]] && spec="vllm==$VERSION" ;;
  sglang) spec="sglang"; [[ "$VERSION" != "latest" ]] && spec="sglang==$VERSION" ;;
esac

echo "== creating $work (python $PYTHON_VERSION)"
uv venv --relocatable --python "$PYTHON_VERSION" "$work"
echo "== installing $spec"
uv pip install --python "$work/bin/python" "$spec" --torch-backend=auto
installed="$("$work/bin/python" -c "import importlib.metadata as m; print(m.version('$ENGINE'))")"
uv pip freeze --python "$work/bin/python" > "$work/lock.txt"
echo "$ENGINE $installed installed $(date -Is)" > "$work/INSTALLED"

if [[ "$VERSION" == "latest" ]]; then
  name="$ENGINE-$installed"
  target="$LLM_ENVS/$name"
  if [[ -e "$target" ]]; then
    echo "ERROR: $ENGINE $installed is already installed at $target; nothing new." >&2
    exit 1
  fi
fi
# Built with --relocatable, so moving the finished environment to its final name keeps its scripts working.
mv "$work" "$target"
trap - EXIT

echo "== done: $ENGINE $installed in $target"
case "$ENGINE" in
  vllm)   echo "   set VLLM_BIN=$target/bin/vllm in the instance" ;;
  sglang) echo "   set SGLANG_PYTHON=$target/bin/python in the instance" ;;
esac
