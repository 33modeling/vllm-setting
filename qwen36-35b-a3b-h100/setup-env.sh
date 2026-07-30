#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Qwen3.6-35B-A3B @ 2xH100 — 환경 셋업 스크립트 (최초 1회만)
# =============================================================================
# 클러스터에 vLLM이 이미 깔려 있으면 이 스크립트는 필요 없다. run.sh가
# PATH → /group-volume/fdmu/.venv → ./.venv 순서로 vllm을 자동 탐색하므로,
# 셋 다 없을 때만 이 스크립트로 ./.venv 를 만들어라.
#
# 하는 일:
#   1. uv가 없으면 사용자 로컬(~/.local/bin)에 설치
#   2. 이 폴더에 .venv 생성 (python 3.11+)
#   3. vLLM 설치 (CUDA torch 백엔드 자동 선택)
#   4. HF 캐시를 group-volume 읽기 전용 캐시로 연결 (다운로드 중복 방지)
#
# 사용:
#   bash setup-env.sh
# =============================================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# --- 1. uv (빠른 파이썬 패키지 관리자) -------------------------------------
if ! command -v uv >/dev/null 2>&1; then
  echo "[setup] uv가 없어 설치합니다 (~/.local/bin)"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

# --- 2. 가상환경 -------------------------------------------------------------
if [[ ! -d .venv ]]; then
  echo "[setup] .venv 생성"
  uv venv --python 3.11 .venv
fi

# --- 3. vLLM ----------------------------------------------------------------
# --torch-backend=auto : 설치된 CUDA 드라이버에 맞는 torch 휠을 자동 선택.
# H100(SM90)은 공식 휠이 지원하므로 별도 빌드가 필요 없다.
echo "[setup] vLLM 설치 (수 분 소요, ~10GB 다운로드)"
uv pip install --python .venv/bin/python -U vllm --torch-backend=auto

# --- 4. HF 캐시 연결 ---------------------------------------------------------
# 모델은 /group-volume/models/* 로컬 경로를 직접 쓰므로 캐시가 필수는 아니지만,
# 토크나이저 등 부속 다운로드가 생기면 group-volume 캐시를 재사용한다.
if [[ -d /group-volume/data/hf_home && -z "${HF_HOME:-}" ]]; then
  echo "export HF_HOME=/group-volume/data/hf_home" >> .venv/bin/activate
  echo "[setup] HF_HOME → /group-volume/data/hf_home (읽기 전용 캐시)"
fi

echo
echo "[setup] 완료. 확인:"
.venv/bin/vllm --version
echo
echo "다음 단계:  ./run.sh   (또는 스모크: LIMIT=10 ./run.sh)"
