#!/usr/bin/env bash
set -euo pipefail

# Hardware-aware advisor for the launch targets shipped by this repository.
# It intentionally ranks known, tested recipes rather than arbitrary models.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage:
  ./recommend-settings.sh [recommend] [options]
  ./recommend-settings.sh system [options]
  ./recommend-settings.sh plan TARGET [options]

Commands:
  recommend        Rank every tracked serving target (default)
  system           Print detected hardware only
  plan TARGET      Explain one target and its recommended launch settings

Options:
  --json                 Machine-readable JSON output
  --gpu-count N          Simulate N identical GPUs
  --gpu-name NAME        Override/simulate the GPU name
  --vram-mib N           Override total VRAM per GPU
  --free-vram-mib N      Override currently free VRAM per GPU
  --compute-cap X.Y      Override CUDA compute capability
  --ram-gib N            Override total system RAM
  --cpu-cores N          Override logical CPU core count
  -h, --help             Show this help

Examples:
  ./recommend-settings.sh
  ./recommend-settings.sh system --json
  ./recommend-settings.sh plan qwen38-27b-4090x2
  ./recommend-settings.sh --gpu-count 2 --gpu-name 'NVIDIA H100 80GB HBM3' \
    --vram-mib 81920 --free-vram-mib 81920 --compute-cap 9.0
EOF
}

die_usage() {
  echo "ERROR: $*" >&2
  echo "Run './recommend-settings.sh --help' for usage." >&2
  exit 64
}

is_uint() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

is_number() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

gib_from_mib() {
  awk -v mib="$1" 'BEGIN { printf "%.1f", mib / 1024 }'
}

cc_less_than() {
  awk -v actual="$1" -v required="$2" 'BEGIN { exit !(actual < required) }'
}

COMMAND="recommend"
TARGET=""
JSON=0
OVERRIDE_GPU_COUNT=""
OVERRIDE_GPU_NAME=""
OVERRIDE_VRAM_MIB=""
OVERRIDE_FREE_VRAM_MIB=""
OVERRIDE_COMPUTE_CAP=""
OVERRIDE_RAM_GIB=""
OVERRIDE_CPU_CORES=""
command_seen=0

while (($#)); do
  case "$1" in
    recommend|system)
      ((command_seen == 0)) || die_usage "only one command may be specified"
      COMMAND="$1"
      command_seen=1
      shift
      ;;
    plan)
      ((command_seen == 0)) || die_usage "only one command may be specified"
      COMMAND="plan"
      command_seen=1
      shift
      (($#)) || die_usage "plan requires a target name"
      TARGET="$1"
      shift
      ;;
    --json)
      JSON=1
      shift
      ;;
    --gpu-count|--gpu-name|--vram-mib|--free-vram-mib|--compute-cap|--ram-gib|--cpu-cores)
      option="$1"
      shift
      (($#)) || die_usage "$option requires a value"
      case "$option" in
        --gpu-count) OVERRIDE_GPU_COUNT="$1" ;;
        --gpu-name) OVERRIDE_GPU_NAME="$1" ;;
        --vram-mib) OVERRIDE_VRAM_MIB="$1" ;;
        --free-vram-mib) OVERRIDE_FREE_VRAM_MIB="$1" ;;
        --compute-cap) OVERRIDE_COMPUTE_CAP="$1" ;;
        --ram-gib) OVERRIDE_RAM_GIB="$1" ;;
        --cpu-cores) OVERRIDE_CPU_CORES="$1" ;;
      esac
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      (($# == 0)) || die_usage "unexpected argument: $1"
      ;;
    -*|*)
      die_usage "unexpected argument: $1"
      ;;
  esac
done

[[ -z "$OVERRIDE_GPU_COUNT" ]] || is_uint "$OVERRIDE_GPU_COUNT" \
  || die_usage "--gpu-count must be a non-negative integer"
[[ -z "$OVERRIDE_VRAM_MIB" ]] || is_uint "$OVERRIDE_VRAM_MIB" \
  || die_usage "--vram-mib must be a non-negative integer"
[[ -z "$OVERRIDE_FREE_VRAM_MIB" ]] || is_uint "$OVERRIDE_FREE_VRAM_MIB" \
  || die_usage "--free-vram-mib must be a non-negative integer"
[[ -z "$OVERRIDE_COMPUTE_CAP" ]] || [[ "$OVERRIDE_COMPUTE_CAP" =~ ^[0-9]+([.][0-9]+)?$ ]] \
  || die_usage "--compute-cap must be a number such as 8.9"
[[ -z "$OVERRIDE_RAM_GIB" ]] || is_number "$OVERRIDE_RAM_GIB" \
  || die_usage "--ram-gib must be a non-negative number"
[[ -z "$OVERRIDE_CPU_CORES" ]] || is_uint "$OVERRIDE_CPU_CORES" \
  || die_usage "--cpu-cores must be a non-negative integer"

TARGET_IDS=(
  qwen38-27b-h100x2
  qwen38-27b-4090x2
  qwen36-27b-4090x2
  qwen3-coder-2080ti
)

declare -A TARGET_MODEL TARGET_BACKEND TARGET_RUNNER TARGET_ENV_FILE
declare -A TARGET_GPU_LABEL TARGET_GPU_PATTERN TARGET_GPU_COUNT
declare -A TARGET_MIN_VRAM TARGET_MIN_FREE TARGET_MIN_CC TARGET_PRIORITY
declare -A TARGET_CONTEXT TARGET_KV TARGET_SEQS TARGET_BATCH TARGET_UTIL TARGET_EXTRA

TARGET_MODEL[qwen38-27b-h100x2]="Qwen/Qwen3.8-27B"
TARGET_BACKEND[qwen38-27b-h100x2]="vLLM"
TARGET_RUNNER[qwen38-27b-h100x2]="./targets/qwen38-27b-h100x2.sh"
TARGET_ENV_FILE[qwen38-27b-h100x2]="targets/qwen38-27b-h100x2.env"
TARGET_GPU_LABEL[qwen38-27b-h100x2]="2x H100 80GB"
TARGET_GPU_PATTERN[qwen38-27b-h100x2]="H100"
TARGET_GPU_COUNT[qwen38-27b-h100x2]=2
TARGET_MIN_VRAM[qwen38-27b-h100x2]=70000
TARGET_MIN_FREE[qwen38-27b-h100x2]=65000
TARGET_MIN_CC[qwen38-27b-h100x2]=8.0
TARGET_PRIORITY[qwen38-27b-h100x2]=40
TARGET_CONTEXT[qwen38-27b-h100x2]=262144
TARGET_KV[qwen38-27b-h100x2]="fp8"
TARGET_SEQS[qwen38-27b-h100x2]=16
TARGET_BATCH[qwen38-27b-h100x2]=16384
TARGET_UTIL[qwen38-27b-h100x2]="0.92"
TARGET_EXTRA[qwen38-27b-h100x2]="BF16 weights; NVLink custom all-reduce; multimodal enabled"

TARGET_MODEL[qwen38-27b-4090x2]="Qwen/Qwen3.8-27B-FP8"
TARGET_BACKEND[qwen38-27b-4090x2]="vLLM"
TARGET_RUNNER[qwen38-27b-4090x2]="./targets/qwen38-27b-4090x2.sh"
TARGET_ENV_FILE[qwen38-27b-4090x2]="targets/qwen38-27b-4090x2.env"
TARGET_GPU_LABEL[qwen38-27b-4090x2]="2x RTX 4090 24GB"
TARGET_GPU_PATTERN[qwen38-27b-4090x2]="RTX 4090"
TARGET_GPU_COUNT[qwen38-27b-4090x2]=2
TARGET_MIN_VRAM[qwen38-27b-4090x2]=20000
TARGET_MIN_FREE[qwen38-27b-4090x2]=19000
TARGET_MIN_CC[qwen38-27b-4090x2]=8.9
TARGET_PRIORITY[qwen38-27b-4090x2]=30
TARGET_CONTEXT[qwen38-27b-4090x2]=65536
TARGET_KV[qwen38-27b-4090x2]="auto"
TARGET_SEQS[qwen38-27b-4090x2]=2
TARGET_BATCH[qwen38-27b-4090x2]=8192
TARGET_UTIL[qwen38-27b-4090x2]="0.90"
TARGET_EXTRA[qwen38-27b-4090x2]="FP8 weights; text-only; NCCL over PCIe"

TARGET_MODEL[qwen36-27b-4090x2]="Qwen/Qwen3.6-27B-FP8"
TARGET_BACKEND[qwen36-27b-4090x2]="vLLM"
TARGET_RUNNER[qwen36-27b-4090x2]="./targets/qwen36-27b-4090x2.sh"
TARGET_ENV_FILE[qwen36-27b-4090x2]=".env"
TARGET_GPU_LABEL[qwen36-27b-4090x2]="2x RTX 4090 24GB"
TARGET_GPU_PATTERN[qwen36-27b-4090x2]="RTX 4090"
TARGET_GPU_COUNT[qwen36-27b-4090x2]=2
TARGET_MIN_VRAM[qwen36-27b-4090x2]=20000
TARGET_MIN_FREE[qwen36-27b-4090x2]=19000
TARGET_MIN_CC[qwen36-27b-4090x2]=8.9
TARGET_PRIORITY[qwen36-27b-4090x2]=20
TARGET_CONTEXT[qwen36-27b-4090x2]=65536
TARGET_KV[qwen36-27b-4090x2]="auto"
TARGET_SEQS[qwen36-27b-4090x2]=2
TARGET_BATCH[qwen36-27b-4090x2]=8192
TARGET_UTIL[qwen36-27b-4090x2]="0.90"
TARGET_EXTRA[qwen36-27b-4090x2]="FP8 weights; text-only; stable coding profile"

TARGET_MODEL[qwen3-coder-2080ti]="Qwen3-Coder-30B-A3B-Instruct GGUF Q4_K_S"
TARGET_BACKEND[qwen3-coder-2080ti]="llama.cpp"
TARGET_RUNNER[qwen3-coder-2080ti]="./qwen3-coder-2080ti/run-llama-server.sh"
TARGET_ENV_FILE[qwen3-coder-2080ti]="qwen3-coder-2080ti/.env"
TARGET_GPU_LABEL[qwen3-coder-2080ti]="2x RTX 2080 Ti 11GB"
TARGET_GPU_PATTERN[qwen3-coder-2080ti]="RTX 2080 Ti"
TARGET_GPU_COUNT[qwen3-coder-2080ti]=2
TARGET_MIN_VRAM[qwen3-coder-2080ti]=10000
TARGET_MIN_FREE[qwen3-coder-2080ti]=9500
TARGET_MIN_CC[qwen3-coder-2080ti]=0
TARGET_PRIORITY[qwen3-coder-2080ti]=10
TARGET_CONTEXT[qwen3-coder-2080ti]=16384
TARGET_KV[qwen3-coder-2080ti]="q8_0/q8_0"
TARGET_SEQS[qwen3-coder-2080ti]=1
TARGET_BATCH[qwen3-coder-2080ti]="n/a"
TARGET_UTIL[qwen3-coder-2080ti]="n/a"
TARGET_EXTRA[qwen3-coder-2080ti]="all layers on GPU; layer split 1,1; llama.cpp preferred"

if [[ "$COMMAND" == "plan" && -z "${TARGET_MODEL[$TARGET]+x}" ]]; then
  die_usage "unknown target '$TARGET' (choose: ${TARGET_IDS[*]})"
fi

declare -a GPU_INDEXES=() GPU_NAMES=() GPU_TOTALS=() GPU_FREES=() GPU_CCS=()

infer_compute_cap() {
  local name="${1,,}"
  case "$name" in
    *h100*) echo "9.0" ;;
    *"rtx 4090"*) echo "8.9" ;;
    *"rtx 3090"*|*"rtx 3080"*|*"rtx 3050"*) echo "8.6" ;;
    *a100*) echo "8.0" ;;
    *"rtx 2080"*) echo "7.5" ;;
    *) echo "" ;;
  esac
}

detect_gpus() {
  local smi="${NVIDIA_SMI_BIN:-}"
  local output=""
  local line index name total free cc

  if [[ -z "$smi" ]]; then
    smi="$(command -v nvidia-smi 2>/dev/null || true)"
  fi
  [[ -n "$smi" && -x "$smi" ]] || return 0

  output="$($smi --query-gpu=index,name,memory.total,memory.free,compute_cap \
    --format=csv,noheader,nounits 2>/dev/null || true)"
  if [[ -z "$output" ]]; then
    output="$($smi --query-gpu=index,name,memory.total,memory.free \
      --format=csv,noheader,nounits 2>/dev/null || true)"
  fi

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    IFS=',' read -r index name total free cc <<< "$line"
    index="$(trim "${index:-}")"
    name="$(trim "${name:-}")"
    total="$(trim "${total:-}")"
    free="$(trim "${free:-}")"
    cc="$(trim "${cc:-}")"
    is_uint "$index" || continue
    is_uint "$total" || continue
    is_uint "$free" || free=0
    [[ "$cc" =~ ^[0-9]+([.][0-9]+)?$ ]] || cc="$(infer_compute_cap "$name")"
    GPU_INDEXES+=("$index")
    GPU_NAMES+=("$name")
    GPU_TOTALS+=("$total")
    GPU_FREES+=("$free")
    GPU_CCS+=("$cc")
  done <<< "$output"
}

detect_gpus

gpu_override=0
for value in "$OVERRIDE_GPU_COUNT" "$OVERRIDE_GPU_NAME" "$OVERRIDE_VRAM_MIB" \
  "$OVERRIDE_FREE_VRAM_MIB" "$OVERRIDE_COMPUTE_CAP"; do
  [[ -z "$value" ]] || gpu_override=1
done

if ((gpu_override)); then
  synthetic_count="${OVERRIDE_GPU_COUNT:-${#GPU_NAMES[@]}}"
  if [[ -z "$OVERRIDE_GPU_COUNT" && "$synthetic_count" == "0" ]]; then
    synthetic_count=1
  fi
  base_name="${OVERRIDE_GPU_NAME:-${GPU_NAMES[0]:-Simulated NVIDIA GPU}}"
  base_total="${OVERRIDE_VRAM_MIB:-${GPU_TOTALS[0]:-0}}"
  base_free="${OVERRIDE_FREE_VRAM_MIB:-${GPU_FREES[0]:-$base_total}}"
  base_cc="${OVERRIDE_COMPUTE_CAP:-${GPU_CCS[0]:-}}"
  GPU_INDEXES=()
  GPU_NAMES=()
  GPU_TOTALS=()
  GPU_FREES=()
  GPU_CCS=()
  for ((i = 0; i < synthetic_count; i++)); do
    GPU_INDEXES+=("$i")
    GPU_NAMES+=("$base_name")
    GPU_TOTALS+=("$base_total")
    GPU_FREES+=("$base_free")
    GPU_CCS+=("$base_cc")
  done
fi

GPU_COUNT=${#GPU_NAMES[@]}
MIN_VRAM_MIB=0
MIN_FREE_VRAM_MIB=0
MIN_COMPUTE_CAP=""
HAS_UNKNOWN_COMPUTE_CAP=0
GPU_NAME_SUMMARY="none"

if ((GPU_COUNT > 0)); then
  MIN_VRAM_MIB="${GPU_TOTALS[0]}"
  MIN_FREE_VRAM_MIB="${GPU_FREES[0]}"
  MIN_COMPUTE_CAP="${GPU_CCS[0]}"
  GPU_NAME_SUMMARY="${GPU_NAMES[0]}"
  mixed_names=0
  for ((i = 0; i < GPU_COUNT; i++)); do
    ((GPU_TOTALS[i] < MIN_VRAM_MIB)) && MIN_VRAM_MIB="${GPU_TOTALS[i]}"
    ((GPU_FREES[i] < MIN_FREE_VRAM_MIB)) && MIN_FREE_VRAM_MIB="${GPU_FREES[i]}"
    if [[ -z "${GPU_CCS[i]}" ]]; then
      HAS_UNKNOWN_COMPUTE_CAP=1
    else
      if [[ -z "$MIN_COMPUTE_CAP" ]] || cc_less_than "${GPU_CCS[i]}" "$MIN_COMPUTE_CAP"; then
        MIN_COMPUTE_CAP="${GPU_CCS[i]}"
      fi
    fi
    [[ "${GPU_NAMES[i]}" == "${GPU_NAMES[0]}" ]] || mixed_names=1
  done
  ((mixed_names == 0)) || GPU_NAME_SUMMARY="mixed NVIDIA GPUs"
fi

MEMINFO_FILE="${MEMINFO_FILE:-/proc/meminfo}"
RAM_TOTAL_MIB=0
RAM_AVAILABLE_MIB=0
if [[ -r "$MEMINFO_FILE" ]]; then
  mem_total_kib="$(awk '/^MemTotal:/ {print $2; exit}' "$MEMINFO_FILE")"
  mem_available_kib="$(awk '/^MemAvailable:/ {print $2; exit}' "$MEMINFO_FILE")"
  is_uint "${mem_total_kib:-}" && RAM_TOTAL_MIB=$((mem_total_kib / 1024))
  is_uint "${mem_available_kib:-}" && RAM_AVAILABLE_MIB=$((mem_available_kib / 1024))
fi
if [[ -n "$OVERRIDE_RAM_GIB" ]]; then
  RAM_TOTAL_MIB="$(awk -v gib="$OVERRIDE_RAM_GIB" 'BEGIN { printf "%d", gib * 1024 }')"
  RAM_AVAILABLE_MIB="$RAM_TOTAL_MIB"
fi

CPU_CORES="$(nproc 2>/dev/null || echo 0)"
[[ -z "$OVERRIDE_CPU_CORES" ]] || CPU_CORES="$OVERRIDE_CPU_CORES"

SHM_MIB="$(df -Pk /dev/shm 2>/dev/null | awk 'NR==2 {printf "%d", $4 / 1024}' || true)"
DISK_FREE_MIB="$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2 {printf "%d", $4 / 1024}' || true)"
SHM_MIB="${SHM_MIB:-0}"
DISK_FREE_MIB="${DISK_FREE_MIB:-0}"

all_gpu_names_match() {
  local pattern="$1"
  ((GPU_COUNT > 0)) || return 1
  for name in "${GPU_NAMES[@]}"; do
    [[ "$name" == *"$pattern"* ]] || return 1
  done
}

declare -A RESULT_FIT RESULT_READY RESULT_SCORE RESULT_REASON

evaluate_target() {
  local id="$1"
  local required_count="${TARGET_GPU_COUNT[$id]}"
  local required_vram="${TARGET_MIN_VRAM[$id]}"
  local required_free="${TARGET_MIN_FREE[$id]}"
  local required_cc="${TARGET_MIN_CC[$id]}"
  local priority="${TARGET_PRIORITY[$id]}"
  local capacity_ok=1
  local readiness_ok=1
  local cc_unknown=0
  local exact=0
  local reasons=()

  if ((GPU_COUNT < required_count)); then
    capacity_ok=0
    reasons+=("needs ${required_count} GPUs; found ${GPU_COUNT}")
  fi
  if ((MIN_VRAM_MIB < required_vram)); then
    capacity_ok=0
    reasons+=("needs at least ${required_vram} MiB per GPU; weakest has ${MIN_VRAM_MIB} MiB")
  fi
  if [[ "$required_cc" != "0" ]]; then
    if ((HAS_UNKNOWN_COMPUTE_CAP)) || [[ -z "$MIN_COMPUTE_CAP" ]]; then
      cc_unknown=1
      reasons+=("compute capability is unknown for at least one GPU; launch preflight must confirm >= ${required_cc}")
    elif cc_less_than "$MIN_COMPUTE_CAP" "$required_cc"; then
      capacity_ok=0
      reasons+=("needs compute capability >= ${required_cc}; weakest GPU is ${MIN_COMPUTE_CAP}")
    fi
  fi

  if ((capacity_ok)) && ((MIN_FREE_VRAM_MIB < required_free)); then
    readiness_ok=0
    reasons+=("capacity fits but only ${MIN_FREE_VRAM_MIB} MiB is free per GPU; free at least ${required_free} MiB")
  fi

  if all_gpu_names_match "${TARGET_GPU_PATTERN[$id]}"; then
    exact=1
  fi

  if ((capacity_ok == 0)); then
    RESULT_FIT[$id]="too_tight"
    RESULT_READY[$id]="false"
    RESULT_SCORE[$id]="$priority"
  elif ((readiness_ok == 0 || cc_unknown == 1)); then
    RESULT_FIT[$id]="marginal"
    RESULT_READY[$id]="false"
    RESULT_SCORE[$id]=$((100 + priority))
  elif ((exact)); then
    RESULT_FIT[$id]="perfect"
    RESULT_READY[$id]="true"
    RESULT_SCORE[$id]=$((300 + priority))
    reasons+=("intended GPU family and launch capacity match")
  else
    RESULT_FIT[$id]="good"
    RESULT_READY[$id]="true"
    RESULT_SCORE[$id]=$((200 + priority))
    reasons+=("capacity fits; recipe was tuned for ${TARGET_GPU_LABEL[$id]}, so benchmark before production use")
  fi

  local joined=""
  for reason in "${reasons[@]}"; do
    [[ -z "$joined" ]] || joined+="; "
    joined+="$reason"
  done
  RESULT_REASON[$id]="$joined"
}

for id in "${TARGET_IDS[@]}"; do
  evaluate_target "$id"
done

SORTED_IDS=()
remaining=("${TARGET_IDS[@]}")
while ((${#remaining[@]})); do
  best_index=0
  best_score="${RESULT_SCORE[${remaining[0]}]}"
  for ((i = 1; i < ${#remaining[@]}; i++)); do
    score="${RESULT_SCORE[${remaining[i]}]}"
    if ((score > best_score)); then
      best_index="$i"
      best_score="$score"
    fi
  done
  SORTED_IDS+=("${remaining[best_index]}")
  unset 'remaining[best_index]'
  remaining=("${remaining[@]}")
done

RECOMMENDATION=""
for id in "${SORTED_IDS[@]}"; do
  if [[ "${RESULT_FIT[$id]}" != "too_tight" ]]; then
    RECOMMENDATION="$id"
    break
  fi
done

print_system_human() {
  echo "System"
  if ((GPU_COUNT == 0)); then
    echo "  GPU:             none detected"
  else
    echo "  GPU:             ${GPU_COUNT}x ${GPU_NAME_SUMMARY}"
    for ((i = 0; i < GPU_COUNT; i++)); do
      echo "    [${GPU_INDEXES[i]}] ${GPU_NAMES[i]} | ${GPU_TOTALS[i]} MiB total | ${GPU_FREES[i]} MiB free | cc ${GPU_CCS[i]:-unknown}"
    done
  fi
  echo "  RAM:             $(gib_from_mib "$RAM_TOTAL_MIB") GiB total, $(gib_from_mib "$RAM_AVAILABLE_MIB") GiB available"
  echo "  CPU:             ${CPU_CORES} logical cores"
  echo "  /dev/shm:        $(gib_from_mib "$SHM_MIB") GiB available"
  echo "  home disk free:  $(gib_from_mib "$DISK_FREE_MIB") GiB"
  ((gpu_override == 0)) || echo "  source:          simulated/overridden GPU values"
}

print_system_json() {
  printf '{"gpu_count":%d,"gpus":[' "$GPU_COUNT"
  for ((i = 0; i < GPU_COUNT; i++)); do
    ((i == 0)) || printf ','
    printf '{"index":%d,"name":"%s","vram_mib":%d,"free_vram_mib":%d,"compute_capability":' \
      "${GPU_INDEXES[i]}" "$(json_escape "${GPU_NAMES[i]}")" "${GPU_TOTALS[i]}" "${GPU_FREES[i]}"
    if [[ -n "${GPU_CCS[i]}" ]]; then
      printf '"%s"' "$(json_escape "${GPU_CCS[i]}")"
    else
      printf 'null'
    fi
    printf '}'
  done
  printf '],"ram_total_mib":%d,"ram_available_mib":%d,"cpu_cores":%d,"shm_available_mib":%d,"disk_free_mib":%d,"simulated":%s}' \
    "$RAM_TOTAL_MIB" "$RAM_AVAILABLE_MIB" "$CPU_CORES" "$SHM_MIB" "$DISK_FREE_MIB" \
    "$([[ "$gpu_override" == "1" ]] && echo true || echo false)"
}

print_target_json() {
  local id="$1"
  printf '{"id":"%s","model":"%s","backend":"%s","runner":"%s","env_file":"%s",' \
    "$(json_escape "$id")" "$(json_escape "${TARGET_MODEL[$id]}")" \
    "$(json_escape "${TARGET_BACKEND[$id]}")" "$(json_escape "${TARGET_RUNNER[$id]}")" \
    "$(json_escape "${TARGET_ENV_FILE[$id]}")"
  printf '"fit":"%s","ready":%s,"score":%d,"reason":"%s",' \
    "${RESULT_FIT[$id]}" "${RESULT_READY[$id]}" "${RESULT_SCORE[$id]}" \
    "$(json_escape "${RESULT_REASON[$id]}")"
  printf '"requirements":{"gpu_count":%d,"min_vram_mib_per_gpu":%d,"min_free_vram_mib_per_gpu":%d,"min_compute_capability":"%s","tuned_for":"%s"},' \
    "${TARGET_GPU_COUNT[$id]}" "${TARGET_MIN_VRAM[$id]}" "${TARGET_MIN_FREE[$id]}" \
    "${TARGET_MIN_CC[$id]}" "$(json_escape "${TARGET_GPU_LABEL[$id]}")"
  printf '"settings":{"max_model_len":%d,"kv_cache_dtype":"%s","max_num_seqs":%d,"max_num_batched_tokens":"%s","gpu_memory_utilization":"%s","notes":"%s"}}' \
    "${TARGET_CONTEXT[$id]}" "$(json_escape "${TARGET_KV[$id]}")" "${TARGET_SEQS[$id]}" \
    "$(json_escape "${TARGET_BATCH[$id]}")" "$(json_escape "${TARGET_UTIL[$id]}")" \
    "$(json_escape "${TARGET_EXTRA[$id]}")"
}

print_recommendation_human() {
  print_system_human
  echo
  echo "Tracked target fit"
  printf '  %-10s %-5s %-28s %-10s %s\n' "FIT" "READY" "TARGET" "BACKEND" "MODEL"
  for id in "${SORTED_IDS[@]}"; do
    printf '  %-10s %-5s %-28s %-10s %s\n' \
      "${RESULT_FIT[$id]}" "${RESULT_READY[$id]}" "$id" "${TARGET_BACKEND[$id]}" "${TARGET_MODEL[$id]}"
    echo "    ${RESULT_REASON[$id]}"
  done
  echo
  if [[ -n "$RECOMMENDATION" ]]; then
    echo "Recommendation: $RECOMMENDATION (${RESULT_FIT[$RECOMMENDATION]})"
    echo "  runner: ${TARGET_RUNNER[$RECOMMENDATION]}"
    echo "  context: ${TARGET_CONTEXT[$RECOMMENDATION]} | KV: ${TARGET_KV[$RECOMMENDATION]} | sequences: ${TARGET_SEQS[$RECOMMENDATION]}"
    if [[ "${RESULT_READY[$RECOMMENDATION]}" != "true" ]]; then
      echo "  Do not launch yet: ${RESULT_REASON[$RECOMMENDATION]}"
    fi
    echo "  Inspect the full plan: ./recommend-settings.sh plan $RECOMMENDATION"
  else
    echo "Recommendation: none of this repository's tracked targets fits."
    echo "  Do not force a 27B recipe onto this hardware. Use llmfit for broad model"
    echo "  discovery, then add a measured target here before treating it as supported."
  fi
}

print_recommendation_json() {
  printf '{"system":'
  print_system_json
  printf ',"recommendation":'
  if [[ -n "$RECOMMENDATION" ]]; then
    printf '"%s"' "$(json_escape "$RECOMMENDATION")"
  else
    printf 'null'
  fi
  printf ',"targets":['
  for ((i = 0; i < ${#SORTED_IDS[@]}; i++)); do
    ((i == 0)) || printf ','
    print_target_json "${SORTED_IDS[i]}"
  done
  printf ']}\n'
}

print_plan_human() {
  local id="$1"
  print_system_human
  echo
  echo "Target plan: $id"
  echo "  model:        ${TARGET_MODEL[$id]}"
  echo "  backend:      ${TARGET_BACKEND[$id]}"
  echo "  tuned for:    ${TARGET_GPU_LABEL[$id]}"
  echo "  fit:          ${RESULT_FIT[$id]}"
  echo "  ready now:    ${RESULT_READY[$id]}"
  echo "  reason:       ${RESULT_REASON[$id]}"
  echo
  echo "Requirements"
  echo "  GPUs:         ${TARGET_GPU_COUNT[$id]}"
  echo "  VRAM/GPU:     >= ${TARGET_MIN_VRAM[$id]} MiB total, >= ${TARGET_MIN_FREE[$id]} MiB free"
  [[ "${TARGET_MIN_CC[$id]}" == "0" ]] || echo "  compute cap:  >= ${TARGET_MIN_CC[$id]}"
  echo
  echo "Recommended settings"
  echo "  MAX_MODEL_LEN=${TARGET_CONTEXT[$id]}"
  echo "  KV cache=${TARGET_KV[$id]}"
  echo "  max sequences=${TARGET_SEQS[$id]}"
  echo "  max batched tokens=${TARGET_BATCH[$id]}"
  echo "  GPU utilization=${TARGET_UTIL[$id]}"
  echo "  ${TARGET_EXTRA[$id]}"
  echo
  echo "Launch"
  echo "  env file: ${TARGET_ENV_FILE[$id]}"
  echo "  ${TARGET_RUNNER[$id]}"
  if [[ "${RESULT_READY[$id]}" != "true" ]]; then
    echo
    echo "Blocked: resolve the fit/readiness reason before launching."
  fi
}

case "$COMMAND" in
  system)
    if ((JSON)); then
      print_system_json
      echo
    else
      print_system_human
    fi
    ;;
  recommend)
    if ((JSON)); then
      print_recommendation_json
    else
      print_recommendation_human
    fi
    ;;
  plan)
    if ((JSON)); then
      printf '{"system":'
      print_system_json
      printf ',"target":'
      print_target_json "$TARGET"
      printf '}\n'
    else
      print_plan_human "$TARGET"
    fi
    ;;
esac
