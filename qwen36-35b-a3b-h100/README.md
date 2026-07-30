# Qwen3.6-35B-A3B @ 2×H100 — vLLM 서빙 + BFCL 에이전트 벤치 평가

`./run.sh` 한 번으로 서빙부터 점수표까지 나오는 원샷 셋업.

## 무엇을 평가하나 (벤치마크·메트릭)

**BFCL v3 (Berkeley Function Calling Leaderboard)** 의 오프라인 채점 카테고리 3종, 총 800문제:

| 카테고리 | 문제 수 | 내용 |
|---|---:|---|
| simple | 400 | 함수 1개 제공 → 올바른 인자로 1회 호출 |
| multiple | 200 | 함수 여러 개 중 올바른 것을 골라 호출 |
| parallel | 200 | 한 질문에 필요한 여러 호출을 동시에 생성 |

- **메트릭: AST 정확도(accuracy)** — 생성된 함수 호출의 이름·파라미터 값을 정답 허용 목록(possible_answer)과 구조적으로 대조해 전부 맞아야 정답. 실행 없이 구조 비교만 하므로 API 키·외부 환경이 필요 없다.
- 채점기는 공식 checker의 단순화 재구현이라 리더보드 공식 수치와 **±수 %p 오차**가 있을 수 있다 (타입 강제변환 등 일부 엣지 케이스 미구현).

### 참조 수치 (돌리기 전 기대값)

- Qwen2.5-1.5B-Instruct: BFCL **Non-live(≒이 3개 카테고리 포함) 30.75%, 전체 48.83%** — [FunReason 논문 보고값](https://arxiv.org/pdf/2505.20192). 소형 모델이라 낮다.
- Qwen3.6-35B-A3B: 공개 BFCL 수치 미확인 — 이 셋업으로 직접 재보는 것이 목적. 동급 MoE 모델은 simple/multiple에서 대체로 85%+ 수준.

## 전제

- 2×H100 (80GB) 노드. 모델은 `/group-volume/models/Qwen3.6-35B-A3B` 에 업로드되어 있음 (fdmu 관례).
- vLLM은 클러스터에 대부분 설치되어 있음 — `run.sh`가 `PATH → /group-volume/fdmu/.venv → ./.venv` 순으로 자동 탐색.
- 평가 데이터(BFCL 800문제)는 첫 실행 때 HuggingFace에서 자동 다운로드(수 MB).

## 빠른 시작

```bash
# (vllm이 어디에도 없을 때만) 환경 셋업 — 상세 주석은 스크립트 참조
bash setup-env.sh

# 스모크 테스트: 카테고리당 10문제 (~2분)
LIMIT=10 ./run.sh

# 전체 800문제 (~10-20분, 서버 로드 포함)
./run.sh
```

끝나면 `results/report.md` 점수표가 stdout에 출력된다.

## run.sh가 하는 일 (순서대로)

1. **프리플라이트** — vllm 바이너리·GPU 2장·VRAM(60GB+)·모델 경로·포트·/dev/shm 확인. 문제가 있으면 실행 전에 명확한 에러로 중단.
2. **vLLM 서버 기동** — `vllm serve <MODEL_DIR>` TP=2, tool-calling 파서(`qwen3_coder`)·reasoning 파서(`qwen3`) 활성화. 백그라운드, 로그 `logs/vllm.log`.
3. **헬스 대기** — `/v1/models` 응답까지 최대 20분(35B 로드는 보통 2~5분). 서버가 죽으면 로그 꼬리를 보여주고 중단.
4. **BFCL 평가** — `bfcl_api_eval.py`가 OpenAI 호환 API로 800문제를 병렬 8-worker로 질의, tool_calls 응답을 AST 채점.
5. **결과 출력·서버 정리** — `results/report.{md,json}`, 오답 30건 샘플 `results/failures.json`. `KEEP_SERVER=1`이면 서버 유지.

## 설정 (환경변수 또는 .env)

| 변수 | 기본값 | 설명 |
|---|---|---|
| `MODEL_DIR` | `/group-volume/models/Qwen3.6-35B-A3B` | 로컬 모델 경로 |
| `SERVED_MODEL_NAME` | `qwen3.6-35b-a3b` | API 상의 모델 이름 |
| `TP_SIZE` | 2 | 텐서 병렬 (GPU 수) |
| `PORT` | 8100 | API 포트 |
| `MAX_MODEL_LEN` | 32768 | 컨텍스트 길이 (BFCL엔 충분) |
| `GPU_MEMORY_UTILIZATION` | 0.92 | KV 캐시 포함 VRAM 사용률 |
| `LIMIT` | 0(전체) | 카테고리당 문제 수 제한 |
| `KEEP_SERVER` | 0 | 1이면 평가 후 서버 유지 |
| `TOOL_CALL_PARSER` | `qwen3_coder` | 모델별 tool-call 파서 |
| `VLLM_BIN` | 자동 탐색 | vllm 실행 파일 직접 지정 |

### 다른 모델 평가 (예: 1.5B 재현)

```bash
MODEL_DIR=/group-volume/models/Qwen2.5-1.5B-Instruct \
SERVED_MODEL_NAME=qwen2.5-1.5b TP_SIZE=1 \
TOOL_CALL_PARSER=hermes REASONING_PARSER="" ./run.sh
```

(Qwen2.5 계열 tool-call 파서는 `hermes`. REASONING_PARSER 빈 값이면 run.sh를 열어 `--reasoning-parser` 줄을 지우거나 `REASONING_PARSER=qwen3`를 그대로 둬도 무해.)

## 트러블슈팅

- **NCCL 에러 / 서버가 로드 중 죽음** → `/dev/shm` 부족(도커면 `--shm-size=16g`), 또는 GPU를 다른 프로세스가 점유. `logs/vllm.log` 확인.
- **`tool_calls`가 비어 있음** → 파서 불일치. `TOOL_CALL_PARSER`를 `hermes`/`qwen3_coder`로 바꿔 재시도.
- **포트 충돌** → `PORT=8200 ./run.sh`.
- **정확도가 리더보드보다 낮음** → 간이 채점기 오차 + 프롬프트 차이. `results/failures.json`에서 오답 유형(파싱 실패 vs 값 불일치)을 먼저 확인.

## 관련

- 로컬(RTX 3050, Qwen2.5-1.5B transformers 직접 구동) 버전: `~/dev/agent-benchmarks/local_eval/` — 같은 채점기, GPU 6GB용. 로컬 실행은 보류 상태.
