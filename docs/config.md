# 설정 레퍼런스


`.env`는 레포 루트에 두는 **로컬 전용** 설정 파일입니다. `cp .env.example .env`로 만들며, 컴퓨터마다 값이 다르므로 `.gitignore`에 등록돼 Git에는 올라가지 않습니다. 모든 스크립트는 시작할 때 이 파일을 읽고, 파일이나 항목이 없으면 아래 기본값으로 동작합니다. **아래 기본값은 2x RTX 4090 서버 기준**이므로 다른 머신에서는 그대로 쓸 수 없고, "실행 가이드 > 2. 최초 설정"의 항목별 점검대로 머신마다 새로 맞춰야 합니다. **값을 바꾸면 서버를 재시작해야 반영됩니다**: `./stop-vllm.sh && ./targets/qwen36-27b-4090x2.sh`.

## 모델·서버 기본

| 변수 | 기본값 | 설명 |
|---|---|---|
| `MODEL` | `Qwen/Qwen3.6-27B-FP8` | 서빙할 모델의 HuggingFace ID. 처음 실행 시 자동 다운로드됩니다. 다른 모델로 바꾸면 `--reasoning-parser`, `--tool-call-parser`가 그 모델과 호환되는지 확인이 필요합니다. |
| `SERVED_MODEL_NAME` | `qwen3.6-27b-fp8` | API에서 노출되는 모델명. 클라이언트(Codex, OpenAI SDK 등)가 요청에 적는 이름이 이것과 일치해야 합니다. HuggingFace ID를 그대로 쓰기 길어서 짧은 별칭을 붙이는 용도입니다. |
| `HOST` | `0.0.0.0` | 서버가 바인딩할 주소. `0.0.0.0`은 모든 인터페이스에서 접속 허용(같은 네트워크의 다른 기기 포함), `127.0.0.1`은 이 컴퓨터에서만 접속 가능. 외부 공개 시에는 방화벽/인증을 함께 구성하세요. |
| `PORT` | `8000` | API 포트. 클라이언트는 `http://localhost:8000/v1`로 접속합니다. 다른 프로그램과 충돌하면 변경하세요. |
| `CUDA_VISIBLE_DEVICES` | `0,1` | 사용할 GPU 번호(nvidia-smi 기준). 예: GPU 1개만 쓰려면 `0`, 2·3번을 쓰려면 `2,3`. |
| `TP_SIZE` | `2` | 텐서 병렬 크기 — 모델을 몇 장의 GPU에 나눠 올릴지. `CUDA_VISIBLE_DEVICES`의 GPU 개수와 일치해야 합니다. |
| `DTYPE` | `auto` | 모델 가중치 연산 자료형. `auto`면 모델 설정을 따릅니다(FP8 모델은 FP8). 보통 바꿀 일 없습니다. |
| `PID_FILE` | `레포/vllm.pid` | 서버 프로세스 ID를 기록할 파일 경로. `stop-vllm.sh`가 종료 대상을 찾을 때 씁니다. 바꿀 일 거의 없습니다. |
| `VLLM_BIN` | (자동 탐색) | vllm 실행파일 경로. 지정하지 않으면 PATH → 레포 안 `./.venv/bin/vllm` 순으로 찾습니다. vLLM을 다른 가상환경에 설치했다면 `VLLM_BIN=/그/경로/bin/vllm`으로 지정하세요. |

## 메모리·컨텍스트

| 변수 | 기본값 | 설명 |
|---|---|---|
| `MAX_MODEL_LEN` | `65536` | 최대 컨텍스트 길이(토큰). 프롬프트+응답 합계의 상한입니다. 크게 잡을수록 KV cache 메모리를 더 예약합니다. 128K가 필요하면 `./use-profile.sh 128k`. OOM이 나면 이 값을 낮추는 게 가장 효과적입니다(`98304` → `65536` 순). |
| `GPU_MEMORY_UTILIZATION` | `0.90` | vLLM이 GPU 메모리의 몇 %까지 쓸지. 모니터가 연결된 GPU라면 화면 출력용 여유가 필요해 `0.85` 정도로 낮추는 게 안전합니다. |
| `MAX_NUM_SEQS` | `2` | 동시에 처리할 요청(시퀀스) 수. Codex/Claude Code 같은 에이전트는 본 요청 외에 서브에이전트·백그라운드 요청을 병렬로 보내므로 기본값을 `2`로 잡았습니다(병렬이 많으면 `3`~`4`로). 에이전트 없이 단일 채팅만 쓴다면 `1`로 낮춰 KV cache를 한 요청에 몰아줄 수 있습니다. |
| `MAX_NUM_BATCHED_TOKENS` | `8192` | 한 스텝에 prefill(프롬프트 처리)할 최대 토큰 수. 키우면 긴 프롬프트 처리 속도가 빨라지지만 활성화 메모리를 더 씁니다. |
| `KV_CACHE_DTYPE` | `auto` | KV cache 자료형. `auto`는 bf16. Qwen3.6-27B는 하이브리드 어텐션이라 KV가 작아 128K도 bf16으로 충분합니다 — `fp8`은 이 모델에선 불필요하고 품질을 약간 깎을 수 있습니다. |

## 기능 스위치 (1=켜짐, 0=꺼짐)

| 변수 | 기본값 | 설명 |
|---|---|---|
| `ENABLE_TOOL_CALLS` | `1` | vLLM이 tool calling(모델이 파일 편집·명령 실행 지시를 구조화된 함수 호출로 응답)을 OpenAI 형식으로 파싱하게 합니다. **Codex/Claude Code 연동에 필수**라 기본으로 켜져 있습니다. tool을 안 쓰는 일반 채팅에는 영향이 없습니다. |
| `ENABLE_PREFIX_CACHING` | `1` | 같은 프롬프트 앞부분(시스템 프롬프트, repo 컨텍스트)을 반복 투입할 때 재계산을 생략합니다. 코딩 에이전트 워크로드에 특히 유리합니다. |
| `ENABLE_CHUNKED_PREFILL` | `1` | 긴 프롬프트 처리를 잘게 쪼개 생성 요청과 섞어 처리합니다. 긴 컨텍스트에서 응답 지연을 줄여줍니다. |
| `DISABLE_CUSTOM_ALL_REDUCE` | `1` | GPU 간 통신에 vLLM 커스텀 구현 대신 NCCL 표준을 씁니다. NVLink 없는 4090 2장 환경에서 안정성이 우선이라 켜져 있습니다. |
| `TRUST_REMOTE_CODE` | `0` | HuggingFace 모델 저장소의 커스텀 파이썬 코드 실행을 허용할지. 보안상 기본 꺼짐. Qwen 계열은 필요 없습니다. |

## 보조 스크립트용

| 변수 | 기본값 | 설명 |
|---|---|---|
| `TIMEOUT_SECONDS` | `30` | `stop-vllm.sh`가 SIGTERM(정상 종료 요청) 후 이 시간만큼 기다렸다가, 안 죽으면 SIGKILL(강제 종료)합니다. |
| `WAIT_READY_SECONDS` | `300` | `health-check.sh`가 서버 준비(`/v1/models` 응답)를 기다리는 최대 시간. 모델 로딩이 느린 환경이면 늘리세요. |
| `REQUEST_TIMEOUT` | `120`(헬스 체크) / `180`(벤치마크) | 개별 요청의 응답 대기 시간. |
| `CHAT_CHECK` | `1` | `health-check.sh`가 models 확인 후 실제 chat completion 요청까지 보낼지. `0`이면 models 확인만 합니다. |
| `BENCH_MAX_TOKENS` | `512` | `benchmark-smoke.sh`가 프롬프트당 생성할 토큰 수. 키울수록 벤치마크가 오래 걸리는 대신 tok/s 측정이 안정적입니다. |
| `BASE_URL` | `http://127.0.0.1:$PORT/v1` | 헬스 체크/벤치마크가 접속할 주소. 원격 서버를 점검할 때만 바꿉니다. |

## Codex 연동용 (`install-codex-config.sh`)

| 변수 | 기본값 | 설명 |
|---|---|---|
| `CODEX_MODEL` | `SERVED_MODEL_NAME` 값 | Codex config에 기록할 모델명. 서버의 서빙 이름과 일치해야 Codex 요청이 통합니다. |
| `CODEX_BASE_URL` | `http://127.0.0.1:$PORT/v1` | Codex가 접속할 서버 주소. 2080 Ti 구성의 llama.cpp(포트 8080)로 보낼 때 바꿉니다. |
| `CODEX_PROFILE` | `qwen-local` | 로컬 모델을 등록할 프로필 이름이자 파일명(`<이름>.config.toml`). `codex --profile <이름>`으로 선택합니다. Codex 기본 모델은 바뀌지 않습니다. |
| `CODEX_HOME` | `~/.codex` | 프로필 파일을 생성할 디렉터리. Codex 설정 위치를 옮겼을 때만 바꿉니다. |

## OpenCode 연동용 (`install-opencode-config.sh`)

| 변수 | 기본값 | 설명 |
|---|---|---|
| `OPENCODE_MODEL` | `SERVED_MODEL_NAME` 값 | opencode.json에 등록할 모델명. 서버의 서빙 이름과 일치해야 합니다. |
| `OPENCODE_BASE_URL` | `http://127.0.0.1:$PORT/v1` | OpenCode가 접속할 서버 주소. 원격 서버를 쓸 때 바꿉니다. |
| `OPENCODE_PROVIDER` | `vllm` | opencode.json 안의 프로바이더 키 이름. 기존에 직접 등록한 키가 있으면 그 이름으로 맞춰 갱신하세요. |
| `OPENCODE_CONFIG` | `~/.config/opencode/opencode.json` | 설정 파일 경로. 프로젝트별 opencode.json을 쓸 때만 바꿉니다. |

# 컨텍스트 튜닝 노트


- 기본 `MAX_MODEL_LEN=65536`은 2x24GB에서 안정성을 우선한 값입니다. `MAX_NUM_SEQS`는 코딩 에이전트의 서브에이전트·백그라운드 병렬 요청을 고려해 기본 `2`입니다 — 에이전트 없이 단일 채팅만 한다면 `1`로 낮춰 KV cache를 한 세션에 몰아줄 수 있고, 병렬이 많으면 `3`~`4`로 올립니다.
- Qwen3.6-27B는 하이브리드 어텐션(레이어 4개 중 1개만 full attention)이라 KV cache가 토큰당 약 64KB로 작아, 128K도 bf16 KV(`KV_CACHE_DTYPE=auto`) 그대로 여유 있게 들어갑니다. `fp8` KV는 이 모델에서는 메모리상 불필요하고 품질을 약간 깎을 수 있어 쓰지 않습니다.
- OOM이 나면 `MAX_MODEL_LEN`을 `98304` 또는 `65536`으로 낮추는 쪽이 가장 효과적입니다.
- `--enable-prefix-caching`: 같은 repo/context를 반복 투입하는 코딩 에이전트 워크로드에 유리합니다.
- `--disable-custom-all-reduce`: NVLink 없는 4090 2장 환경에서 안정성을 우선합니다.
- `ENABLE_TOOL_CALLS`: 기본 `1` — OpenAI tool calling을 vLLM parser(`qwen3_coder`)로 처리합니다. 코딩 에이전트(Codex/Claude Code)에 필수이며, tool을 쓰지 않는 순수 채팅 서빙만 한다면 `0`으로 꺼도 됩니다.
- 2080 Ti는 Turing(SM 7.5)이므로 FP8 모델을 사용하지 않습니다. 외부 접근이 필요할 때만 `HOST=0.0.0.0`으로 바꾸고 방화벽/리버스 프록시 인증을 함께 설정합니다.

