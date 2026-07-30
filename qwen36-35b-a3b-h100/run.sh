#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Qwen3.6-35B-A3B @ 2xH100 — 원샷 실행: vLLM 서빙 → BFCL 평가 → 점수 출력
# =============================================================================
# 이 스크립트 하나로 끝난다:
#   1. 프리플라이트 (GPU 2장·VRAM·모델 경로·포트·vllm 바이너리 확인)
#   2. vLLM OpenAI 서버 기동 (TP=2, 백그라운드, logs/vllm.log)
#   3. /v1/models 응답까지 대기 (기본 최대 20분 — 최초 로드는 수 분 걸림)
#   4. BFCL simple/multiple/parallel 800문제 평가 (bfcl_api_eval.py)
#   5. results/report.md 점수표 출력 후 서버 종료
#
# 사용:
#   ./run.sh                 # 전체 800문제
#   LIMIT=10 ./run.sh        # 카테고리당 10문제 스모크
#   KEEP_SERVER=1 ./run.sh   # 평가 후 서버 유지 (다른 실험 이어서 할 때)
#
# 다른 모델 평가 (예: Qwen2.5-1.5B-Instruct, H100 1장이면 TP_SIZE=1):
#   MODEL_DIR=/group-volume/models/Qwen2.5-1.5B-Instruct \
#   SERVED_MODEL_NAME=qwen2.5-1.5b TP_SIZE=1 ./run.sh
#
# 설정 오버라이드는 환경변수 또는 이 폴더의 .env 파일로.
# =============================================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ -f .env ]]; then
  set -a; source .env; set +a
fi

MODEL_DIR="${MODEL_DIR:-/group-volume/models/Qwen3.6-35B-A3B}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-qwen3.6-35b-a3b}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8100}"
TP_SIZE="${TP_SIZE:-2}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-32768}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.92}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-16}"
TOOL_CALL_PARSER="${TOOL_CALL_PARSER:-qwen3_coder}"   # Qwen3.x 계열 공통
REASONING_PARSER="${REASONING_PARSER:-qwen3}"
WAIT_SECS="${WAIT_SECS:-1200}"
LIMIT="${LIMIT:-0}"
KEEP_SERVER="${KEEP_SERVER:-0}"
export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0,1}"

mkdir -p logs results

# --- 프리플라이트 ------------------------------------------------------------
# vllm 탐색 순서: VLLM_BIN 명시 > PATH > fdmu 클러스터 venv > 이 폴더 .venv
if [[ -z "${VLLM_BIN:-}" ]]; then
  if command -v vllm >/dev/null 2>&1; then VLLM_BIN="$(command -v vllm)"
  elif [[ -x /group-volume/fdmu/.venv/bin/vllm ]]; then VLLM_BIN=/group-volume/fdmu/.venv/bin/vllm
  elif [[ -x "$SCRIPT_DIR/.venv/bin/vllm" ]]; then VLLM_BIN="$SCRIPT_DIR/.venv/bin/vllm"
  else
    echo "ERROR: vllm을 찾지 못했습니다. 먼저 'bash setup-env.sh'를 실행하거나 VLLM_BIN을 지정하세요." >&2
    exit 1
  fi
fi

command -v nvidia-smi >/dev/null || { echo "ERROR: nvidia-smi 없음 — GPU 노드에서 실행하세요." >&2; exit 1; }
gpu_count="$(nvidia-smi --list-gpus | wc -l)"
(( gpu_count >= TP_SIZE )) || { echo "ERROR: GPU ${gpu_count}장 < TP_SIZE=${TP_SIZE}" >&2; exit 1; }

min_vram="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | sort -n | head -1)"
if (( TP_SIZE == 2 )) && (( min_vram < 60000 )); then
  echo "ERROR: VRAM ${min_vram}MiB — 35B(BF16 ~70GB)는 H100급 2장이 필요합니다." >&2
  exit 1
fi

[[ -e "$MODEL_DIR" ]] || { echo "ERROR: 모델 경로 없음: $MODEL_DIR" >&2; exit 1; }

if ss -tln 2>/dev/null | awk '{print $4}' | grep -q ":$PORT\$"; then
  echo "ERROR: 포트 $PORT 사용 중 — PORT를 바꾸거나 기존 서버를 내리세요." >&2
  exit 1
fi

shm_kib="$(df -k /dev/shm 2>/dev/null | awk 'NR==2 {print $2}')"
if [[ "$shm_kib" =~ ^[0-9]+$ ]] && (( shm_kib < 2097152 )); then
  echo "WARNING: /dev/shm $((shm_kib/1024))MiB — TP=2 NCCL이 실패할 수 있습니다 (docker면 --shm-size=16g)." >&2
fi

# --- 서버 기동 ---------------------------------------------------------------
echo "[run] vLLM 기동: $MODEL_DIR (TP=$TP_SIZE, port=$PORT)"
nohup "$VLLM_BIN" serve "$MODEL_DIR" \
  --served-model-name "$SERVED_MODEL_NAME" \
  --host "$HOST" --port "$PORT" \
  --tensor-parallel-size "$TP_SIZE" \
  --max-model-len "$MAX_MODEL_LEN" \
  --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION" \
  --max-num-seqs "$MAX_NUM_SEQS" \
  --enable-prefix-caching \
  --disable-custom-all-reduce \
  --enable-auto-tool-choice --tool-call-parser "$TOOL_CALL_PARSER" \
  --reasoning-parser "$REASONING_PARSER" \
  > logs/vllm.log 2>&1 &
SERVER_PID=$!
echo "$SERVER_PID" > logs/vllm.pid

cleanup() {
  if [[ "$KEEP_SERVER" != "1" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "[run] 서버 종료 (pid $SERVER_PID)"
    kill "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# --- 헬스 대기 ---------------------------------------------------------------
echo -n "[run] 서버 준비 대기 (최대 ${WAIT_SECS}s) "
for ((i=0; i<WAIT_SECS; i+=5)); do
  if curl -sf "http://$HOST:$PORT/v1/models" >/dev/null 2>&1; then
    echo " OK (${i}s)"
    break
  fi
  kill -0 "$SERVER_PID" 2>/dev/null || { echo; echo "ERROR: 서버 조기 종료 — logs/vllm.log 마지막 50줄:"; tail -50 logs/vllm.log; exit 1; }
  echo -n "."
  sleep 5
done
curl -sf "http://$HOST:$PORT/v1/models" >/dev/null || { echo "ERROR: ${WAIT_SECS}s 내 미기동 — logs/vllm.log 확인"; exit 1; }

# --- 평가 --------------------------------------------------------------------
EVAL_ARGS=(--base-url "http://$HOST:$PORT/v1" --model "$SERVED_MODEL_NAME")
(( LIMIT > 0 )) && EVAL_ARGS+=(--limit "$LIMIT")
python3 bfcl_api_eval.py "${EVAL_ARGS[@]}"

echo
echo "================ 결과 ================"
cat results/report.md
echo "======================================"
echo "상세: results/report.json · 오답 샘플: results/failures.json · 서버 로그: logs/vllm.log"
