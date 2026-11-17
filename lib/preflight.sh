# Shared preflight checks for targets/vllm-serve.sh and targets/sglang-serve.sh.
# Each check prints what is wrong and how to fix it, then exits 1. Source this file; it defines functions only.

preflight_executable() {  # <path-or-name> <label> <install hint>
  local bin="$1" label="$2" hint="$3"
  if [[ "$bin" == */* ]]; then
    [[ -x "$bin" ]] && return 0
    echo "ERROR: $label '$bin' does not exist or is not executable." >&2
  else
    command -v "$bin" >/dev/null 2>&1 && return 0
    echo "ERROR: $label '$bin' is not on PATH." >&2
  fi
  echo "       $hint" >&2
  exit 1
}

preflight_gpus() {  # uses CUDA_VISIBLE_DEVICES and TP_SIZE
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "ERROR: nvidia-smi not found — no NVIDIA driver on this machine?" >&2
    exit 1
  fi
  local count requested idx
  count="$(nvidia-smi --list-gpus 2>/dev/null | wc -l)"
  IFS=',' read -ra requested <<< "$CUDA_VISIBLE_DEVICES"
  if (( count < ${#requested[@]} )) || (( count < TP_SIZE )); then
    echo "ERROR: not enough GPUs: found $count, need ${#requested[@]} (CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES, TP_SIZE=$TP_SIZE)." >&2
    exit 1
  fi
  if (( TP_SIZE > ${#requested[@]} )); then
    echo "ERROR: TP_SIZE=$TP_SIZE is larger than the ${#requested[@]} GPU(s) in CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES." >&2
    exit 1
  fi
  for idx in "${requested[@]}"; do
    if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx >= count )); then
      echo "ERROR: CUDA_VISIBLE_DEVICES contains '$idx' but GPU indexes are 0..$((count - 1)) (see nvidia-smi -L)." >&2
      exit 1
    fi
  done
}

preflight_model() {  # <model id or path>
  local model="$1"
  if [[ -z "$model" ]]; then
    echo "ERROR: MODEL is empty. Set a HuggingFace ID (Org/Name) or a local path." >&2
    exit 1
  fi
  if [[ "$model" == /* || "$model" == ./* || "$model" == ~* ]] && [[ ! -e "$model" ]]; then
    echo "ERROR: MODEL points to a local path that does not exist: $model" >&2
    exit 1
  fi
}

preflight_port() {  # <port>
  if ss -tln 2>/dev/null | awk '{print $4}' | grep -q ":$1\$"; then
    echo "ERROR: port $1 is already in use — another server is running there. Change PORT or stop it." >&2
    exit 1
  fi
}

preflight_shm_warning() {
  local shm_kib
  shm_kib="$(df -k /dev/shm 2>/dev/null | awk 'NR==2 {print $2}')"
  if [[ "$shm_kib" =~ ^[0-9]+$ ]] && (( shm_kib < 1048576 )) && (( TP_SIZE > 1 )); then
    echo "WARNING: /dev/shm is only $((shm_kib / 1024)) MiB; NCCL may fail with TP_SIZE=$TP_SIZE." >&2
  fi
}
