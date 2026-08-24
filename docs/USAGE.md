# 사용 방법

설치부터 문제 해결까지, 실제 명령 단위로 정리한다. 타깃별 설정값의 근거는 [targets.md](targets.md), 변수 하나하나의 의미는 [config.md](config.md), 에이전트 연동 절차 원본은 [agents.md](agents.md)에 있다. 이 문서는 그 위에 **전체 옵션 목록·오버라이드 규칙·에러 메시지 대응표·타깃 추가 절차**를 더한다. 내부 로직은 [CODE.md](CODE.md)를 본다.

## 1. 사전 요구사항

### 1.1 공통

| 항목 | 요구 | 확인 |
|---|---|---|
| OS | Linux (GNU coreutils 필요) | `df --output=avail`이 동작하면 OK |
| 셸 | bash 4.4 이상 (설정 로드가 `mapfile -d`를 씀) | `bash --version` |
| NVIDIA 드라이버 | 필수 | `nvidia-smi -L` |
| `curl` | 필수 | `command -v curl` |
| `ss` (iproute2) | 사실상 필수 | `command -v ss` |
| `jq` | 선택 (응답 본문 출력용) | `command -v jq` |
| `/dev/shm` | 1 GiB 이상 권장 | `df -h /dev/shm` |

`ss`가 없으면 포트 점유 검사가 조용히 통과하고 `stop-vllm.sh`의 두 번째 탐색 경로가 빠진다. 에러는 나지 않지만 안전장치가 줄어든다.

### 1.2 타깃별

| 타깃 | GPU | 최소 VRAM 검사 | compute capability | 추가 요구 |
|---|---|---|---|---|
| `qwen36-27b-4090x2` | 2장 | 20,000 MiB | 검사 없음 (FP8 모델이므로 실제로는 8.9+ 필요) | 디스크 약 30 GiB |
| `qwen38-27b-h100x2` | 2장 | 70,000 MiB | 검사 없음 | vLLM 0.17.0+, 디스크 약 55 GiB |
| `qwen38-27b-4090x2` | 2장 | 20,000 MiB | **8.9 이상 강제** | vLLM 0.17.0+, 디스크 약 30 GiB |
| `qwen3-coder-2080ti` (llama.cpp) | 2장 | 검사 없음 | 없음 | `git`, `cmake`, `nvcc`, C/C++ 빌드 도구 |
| `qwen3-coder-2080ti` (vLLM) | 2장 | 10,000 MiB | 없음 | `vllm` (별도 venv) |

## 2. 설치

### 2.1 vLLM 설치 (타깃 3종 공통)

세 타깃 모두 `VLLM_BIN` → `PATH` → `<repo>/.venv/bin/vllm` 순으로 실행파일을 찾는다.

```bash
cd /path/to/vllm-setting
uv venv
source .venv/bin/activate
uv pip install -U vllm --torch-backend=auto
```

다른 위치에 이미 설치돼 있으면 venv를 만들지 않고 지정만 해도 된다.

```bash
VLLM_BIN=/opt/venvs/vllm/bin/vllm ./targets/qwen36-27b-4090x2.sh
```

명령 앞에 붙인 값은 설정 파일보다 우선한다(§4.4).

### 2.2 설정 파일 준비

```bash
cp .env.example .env          # qwen36 타깃 + 모든 루트 보조 스크립트가 읽음
```

Qwen3.8 타깃은 설정 파일이 **없어도 동작한다** — 스크립트 내장 기본값과 `.env.example`의 값이 같기 때문이다. 값을 바꾸고 싶을 때만 복사한다.

```bash
cp targets/qwen38-27b-h100x2.env.example targets/qwen38-27b-h100x2.env
cp targets/qwen38-27b-4090x2.env.example targets/qwen38-27b-4090x2.env
```

실행 권한은 이미 Git에 `100755`로 들어 있으므로 `chmod +x`는 필요 없다(README의 안내는 무해하지만 불필요).

### 2.3 확인해야 할 항목

`.env`(또는 타깃 `.env`)를 이 머신에 맞춰 점검한다. 기본값은 2x RTX 4090 기준이다.

1. `nvidia-smi -L`로 GPU 개수와 인덱스 확인 → `CUDA_VISIBLE_DEVICES`, `TP_SIZE`
2. `nvidia-smi --query-gpu=memory.total --format=csv`로 VRAM 확인 → `MAX_MODEL_LEN`, `GPU_MEMORY_UTILIZATION`
3. `ss -tln | grep :8000`으로 포트 확인 → `PORT`
4. `df -h ~`로 디스크 확인 (모델 30~55 GiB)
5. `df -h /dev/shm`으로 1 GiB 이상 확인
6. 외부 노출 여부 결정 → `HOST` (`0.0.0.0`은 모든 인터페이스, `127.0.0.1`은 로컬만)

## 3. 대표 실행 경로

### 3.1 Qwen3.6-27B-FP8 @ 2x RTX 4090 (기본)

```bash
cp .env.example .env
./targets/qwen36-27b-4090x2.sh     # 포그라운드로 뜸
```

다른 터미널에서:

```bash
./health-check.sh                  # /v1/models 대기 → chat completion 1회
./benchmark-smoke.sh               # 코딩 프롬프트 3종
./stop-vllm.sh                     # 종료
```

컨텍스트 길이를 바꾸려면 프로필을 전환한다.

```bash
./use-profile.sh 64k               # MAX_MODEL_LEN=65536  (안정 기본값)
./use-profile.sh 128k              # MAX_MODEL_LEN=131072 (타임아웃도 함께 늘어남)
```

> `use-profile.sh`는 `.env`를 **통째로 교체**한다. `.env`에 직접 추가한 `CODEX_MODEL` 같은 항목은 사라진다(직전 `.env`는 `.env.backup.<타임스탬프>`로 남는다). 또한 새 `.env`는 `chmod 600`이 되므로 다른 계정으로는 읽을 수 없게 된다.

### 3.2 Qwen3.8-27B BF16 @ 2x H100 80GB

```bash
cp targets/qwen38-27b-h100x2.env.example targets/qwen38-27b-h100x2.env   # 선택
./targets/qwen38-27b-h100x2.sh
```

MTP 투기적 디코딩(speculative decoding)을 켜려면:

```bash
ENABLE_MTP=1 ./targets/qwen38-27b-h100x2.sh
```

`targets/qwen38-27b-h100x2.env`에 `ENABLE_MTP=0`이 적혀 있어도 명령줄 값이 이긴다(§4.4).

검증과 종료는 §5.2의 방법을 쓴다.

### 3.3 Qwen3.8-27B-FP8 @ 2x RTX 4090

```bash
cp targets/qwen38-27b-4090x2.env.example targets/qwen38-27b-4090x2.env   # 선택
./targets/qwen38-27b-4090x2.sh
```

### 3.4 Qwen3-Coder-30B GGUF @ 2x RTX 2080 Ti

루트와 완전히 분리된 경로다.

```bash
cd qwen3-coder-2080ti
cp .env.example .env
./install-llama-cpp.sh             # clone + CUDA(sm75) 빌드
./download-gguf.sh                 # 기본 Q4_K_S, 약 17.5 GB
./run-llama-server.sh              # http://127.0.0.1:8080/v1 (포그라운드)
```

다른 터미널에서:

```bash
cd qwen3-coder-2080ti
BACKEND=llama ./health-check.sh
./stop-server.sh
```

품질 우선 변형:

```bash
GGUF_QUANT=Q4_K_M ./download-gguf.sh
MODEL_PATH="$PWD/models/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf" \
  LLAMA_CTX_SIZE=16384 ./run-llama-server.sh
```

vLLM 대안 경로:

```bash
cd qwen3-coder-2080ti
python3 -m venv .venv-vllm && source .venv-vllm/bin/activate
pip install -U pip vllm
./run-vllm-server.sh               # http://127.0.0.1:8000/v1
BACKEND=vllm ./health-check.sh
```

### 3.5 백그라운드 실행 (systemd --user)

run 스크립트는 `exec`으로 포그라운드에 남는다. 터미널을 닫아도 유지하려면 systemd를 쓴다. **Qwen3.6 타깃 전용 유닛만 제공된다.**

```bash
./install-systemd-user.sh                        # 유닛 설치 + enable
systemctl --user start vllm-qwen36.service
systemctl --user status vllm-qwen36.service
journalctl --user -u vllm-qwen36.service -f
systemctl --user restart vllm-qwen36.service
systemctl --user stop vllm-qwen36.service
```

설치 스크립트 자체 옵션(기존 문서에 없음):

```bash
SERVICE_NAME=vllm-alt.service ./install-systemd-user.sh    # 유닛 파일 이름 변경
START_NOW=1 ./install-systemd-user.sh                      # 설치 직후 restart까지
```

부팅 후 자동 시작이 필요하면: `loginctl enable-linger "$USER"`.

## 4. 옵션·환경변수 전체 목록

### 4.1 루트 `.env` — 모델과 서버

| 변수 | 기본값 | 읽는 곳 | `.env.example` |
|---|---|---|:-:|
| `MODEL` | `Qwen/Qwen3.6-27B-FP8` | qwen36 타깃, `stop-vllm.sh` | O |
| `SERVED_MODEL_NAME` | `qwen3.6-27b-fp8` | qwen36 타깃, 보조 3종, installer 2종 | O |
| `HOST` | `0.0.0.0` | qwen36 타깃, health-check, benchmark | O |
| `PORT` | `8000` | 거의 전부 | O |
| `CUDA_VISIBLE_DEVICES` | `0,1` | qwen36 타깃 | O |
| `TP_SIZE` | `2` | qwen36 타깃 | O |
| `DTYPE` | `auto` | qwen36 타깃 | — |
| `PID_FILE` | `<repo>/vllm.pid` | qwen36 타깃, `stop-vllm.sh` | — |
| `VLLM_BIN` | 자동 탐색 | 타깃 3종 | — |
| `ENV_FILE` | 타깃별 기본 경로 | **qwen38 타깃 2종만** | — |

### 4.2 루트 `.env` — 메모리·컨텍스트·스위치

| 변수 | qwen36 | q38-h100 | q38-4090 | 효과 |
|---|---|---|---|---|
| `MAX_MODEL_LEN` | `65536` | `262144` | `65536` | `--max-model-len` |
| `GPU_MEMORY_UTILIZATION` | `0.90` | `0.92` | `0.90` | `--gpu-memory-utilization` |
| `MAX_NUM_SEQS` | `2` | `16` | `2` | `--max-num-seqs` |
| `MAX_NUM_BATCHED_TOKENS` | `8192` | `16384` | `8192` | `--max-num-batched-tokens` |
| `KV_CACHE_DTYPE` | `auto` | `fp8` | `auto` | `--kv-cache-dtype` |
| `ENABLE_PREFIX_CACHING` | `1` | `1` | `1` | `--enable-prefix-caching` |
| `ENABLE_CHUNKED_PREFILL` | `1` | `1` | `1` | `--enable-chunked-prefill` |
| `DISABLE_CUSTOM_ALL_REDUCE` | `1` | `0` | `1` | `--disable-custom-all-reduce` |
| `ENABLE_TOOL_CALLS` | `1` | `1` | `1` | `--enable-auto-tool-choice --tool-call-parser qwen3_coder` |
| `TRUST_REMOTE_CODE` | `0` | `0` | `0` | `--trust-remote-code` |
| `LANGUAGE_MODEL_ONLY` | **없음**(항상 켜짐) | `0` | `1` | `--language-model-only` |
| `ENABLE_MTP` | — | `0` | — | `--speculative-config` |
| `MTP_NUM_SPECULATIVE_TOKENS` | — | `3` | — | 위 JSON의 `num_speculative_tokens` |

스위치는 **문자열 `1`일 때만** 켜진다. `true`/`yes`/`on`은 꺼진 것으로 취급된다.

`qwen36-27b-4090x2.sh`에는 `LANGUAGE_MODEL_ONLY` 변수가 없고 `--language-model-only`가 조건 없이 붙는다. 이 타깃에서 이미지 입력이 필요하면 `.env`가 아니라 스크립트를 고쳐야 한다.

### 4.3 보조 스크립트 · installer

| 변수 | 기본값 | 읽는 스크립트 | `.env.example` |
|---|---|---|:-:|
| `TIMEOUT_SECONDS` | `30` (`128k` 프로필은 45) | `stop-vllm.sh` | O |
| `WAIT_READY_SECONDS` | `300` (`128k`는 420) | `health-check.sh` | O |
| `REQUEST_TIMEOUT` | 내장 120/180, **`.env`가 있으면 120** | health-check, benchmark | O |
| `CHAT_CHECK` | `1` | `health-check.sh` | O |
| `BENCH_MAX_TOKENS` | `512` | `benchmark-smoke.sh` | — |
| `BASE_URL` | `http://<HOST 또는 127.0.0.1>:$PORT/v1` | health-check, benchmark | — |
| `CODEX_MODEL` | `$SERVED_MODEL_NAME` | `install-codex-config.sh` | 주석 |
| `CODEX_BASE_URL` | `http://127.0.0.1:$PORT/v1` | 〃 | 주석 |
| `CODEX_PROFILE` | `qwen-local` | 〃 | — |
| `CODEX_HOME` | `~/.codex` | 〃 | — |
| `OPENCODE_MODEL` | `$SERVED_MODEL_NAME` | `install-opencode-config.sh` | — |
| `OPENCODE_BASE_URL` | `http://127.0.0.1:$PORT/v1` | 〃 | — |
| `OPENCODE_PROVIDER` | `vllm` | 〃 | — |
| `OPENCODE_CONFIG` | `~/.config/opencode/opencode.json` | 〃 | — |
| `SERVICE_NAME` | `vllm-qwen36.service` | `install-systemd-user.sh` | — |
| `START_NOW` | `0` | 〃 | — |
| `XDG_CONFIG_HOME` | `~/.config` | 〃 (읽기만) | — |
| `HF_HOME` | `~/.cache/huggingface` | 타깃 3종 (읽기만) | — |

`REQUEST_TIMEOUT`의 "벤치마크 기본 180"은 `.env`가 **없을 때만** 적용된다. `.env.example`을 복사했다면 벤치마크도 120초를 쓴다.

### 4.4 명령줄 오버라이드가 통하는가

스크립트는 `set -a; source <설정파일>` **직후에 소스 이전의 환경을 되돌려 놓고**, 그다음 `${VAR:-기본값}`으로 빈 자리를 채운다. 우선순위는 다음과 같다.

**명령줄(상속된 환경) > 설정 파일 > 스크립트 내장 기본값**

확인:

```
$ PORT=9999 ./health-check.sh
Checking vLLM at http://127.0.0.1:9999/v1      # 명령줄이 .env의 8000을 이김

$ ./health-check.sh
Checking vLLM at http://127.0.0.1:8000/v1      # 오버라이드가 없으면 .env 값
```

| 상황 | 결과 |
|---|---|
| 설정 파일에 그 변수 줄이 **있음** | 명령줄 값이 **적용됨** |
| 설정 파일에 그 변수 줄이 **없음**(또는 주석) | 명령줄 값이 **적용됨** |
| 설정 파일 자체가 없음 | 명령줄 값이 **적용됨** |

설정 파일을 읽는 12개 스크립트 전부에 대해, 각자 읽는 파일의 변수를 하나씩 넘겨 전수 확인했다. 루트 `.env` 20개, `targets/qwen38-27b-h100x2.env` 19개, `targets/qwen38-27b-4090x2.env` 17개, `qwen3-coder-2080ti/.env` 16개 — 전부 통한다. **예전에는 이 값들이 전부 무시됐다**(설정 파일이 이겼다). 그때 쓰던 우회법(`.env`를 잠시 치우기 등)은 더 이상 필요 없다.

주의 두 가지.

- 셸에서 `export` 하지 않은 변수는 자식 프로세스 환경에 들어가지 않아 오버라이드로 인식되지 않는다. `PORT=9999 ./health-check.sh`처럼 명령 앞에 붙이거나 `export PORT=9999`를 쓴다.
- 반대로 `PORT`·`HOST`처럼 흔한 이름이 셸에 이미 `export` 돼 있으면 설정 파일보다 그 값이 우선한다. 설정 파일 값이 반영되지 않으면 `env | grep -E '^(PORT|HOST|MODEL)='`를 먼저 확인한다.

`agents.md`의 "방법 A"(`.env`에 `CODEX_MODEL` 영구 저장)와 "방법 B"(명령줄 1회성 지정)는 함께 써도 된다. 같은 변수라면 방법 B가 이긴다.

### 4.5 타깃 스크립트에 추가 인자 넘기기

세 타깃 모두 마지막이 `exec "$VLLM_BIN" "${args[@]}" "$@"`이므로, 스크립트에 준 인자가 그대로 `vllm serve`로 전달된다.

```bash
./targets/qwen36-27b-4090x2.sh --api-key mysecret
./targets/qwen38-27b-h100x2.sh --swap-space 8
```

같은 플래그를 스크립트가 이미 넣었다면 나중 값(뒤쪽)이 vLLM에서 우선하는지는 vLLM 인자 파서에 달렸다. 새 플래그를 붙이는 용도로만 쓰는 편이 안전하다.

## 5. Qwen3.8 타깃 운영 (보조 스크립트와의 간극)

### 5.1 무엇이 다른가

`stop-vllm.sh`·`health-check.sh`·`benchmark-smoke.sh`는 루트 `.env`만 읽고, 그 `.env`는 `SERVED_MODEL_NAME=qwen3.6-27b-fp8`을 담고 있다. Qwen3.8 서버를 상대할 때는 다른 값을 **명령줄로 넘긴다.** §4.4대로 명령줄이 설정 파일을 이기므로, 기존 문서와 `targets/*.env.example` 주석의 아래 안내가 그대로 동작한다.

```bash
PORT=8000 SERVED_MODEL_NAME=qwen3.8-27b ./health-check.sh
```

### 5.2 명령 모음

**종료.**

```bash
PID_FILE=./vllm-qwen38-h100x2.pid ./stop-vllm.sh
PID_FILE=./vllm-qwen38-4090x2.pid ./stop-vllm.sh
```

**준비·응답 확인.**

```bash
PORT=8000 SERVED_MODEL_NAME=qwen3.8-27b ./health-check.sh
PORT=8000 SERVED_MODEL_NAME=qwen3.8-27b ./benchmark-smoke.sh
```

**서빙 이름만 확인하려면 curl로도 된다.**

```bash
curl -fsS http://127.0.0.1:8000/v1/models | jq -r '.data[].id'
```

**응답 본문을 길게 보려면 curl을 직접 쓴다.**

```bash
curl -fsS http://127.0.0.1:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.8-27b","messages":[{"role":"user","content":"Reply with exactly: OK"}],"temperature":0,"max_tokens":64}' \
  | jq -r '.choices[0].message.content'
```

`max_tokens`를 16보다 넉넉히 잡는다. 타깃 스크립트가 `--reasoning-parser qwen3`을 항상 붙이므로 thinking 출력이 예산을 먼저 소진하면 `content`가 빈 문자열로 나올 수 있다. `health-check.sh`의 chat 검사는 `max_tokens=16` 고정이라 같은 이유로 빈 출력이 나올 수 있고, 이는 실패가 아니다(§8.3).

**에이전트 등록.**

```bash
CODEX_MODEL=qwen3.8-27b ./install-codex-config.sh
OPENCODE_MODEL=qwen3.8-27b ./install-opencode-config.sh
```

## 6. 코딩 에이전트 연결 (요약)

전체 절차와 주의사항은 [agents.md](agents.md)에 있다. 여기서는 명령만 정리한다.

**Codex CLI** — 기본 모델은 유지되고, 프로필로만 전환한다.

```bash
./install-codex-config.sh            # ~/.codex/qwen-local.config.toml 생성
codex                                # 원래 기본 모델
codex --profile qwen-local           # 로컬 vLLM
codex --profile qwen-local --yolo    # 승인 프롬프트 생략
```

생성 결과를 미리 보고 싶으면 임시 디렉터리로 돌려본다(홈은 건드리지 않는다).

```bash
CODEX_HOME=/tmp/codex-preview ./install-codex-config.sh && cat /tmp/codex-preview/qwen-local.config.toml
```

**OpenCode**

```bash
./install-opencode-config.sh         # ~/.config/opencode/opencode.json의 provider.vllm만 갱신
opencode                             # /models로 선택
opencode -m vllm/qwen3.6-27b-fp8     # 바로 지정
```

같은 방식으로 미리 보기가 가능하다: `OPENCODE_CONFIG=/tmp/oc.json ./install-opencode-config.sh`.

**Claude Code** — Anthropic Messages API 형식이라 LiteLLM 프록시가 필요하다. 최근 vLLM은 `/v1/messages`를 자체 지원하기도 하므로, 먼저 확인해 본다.

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8000/v1/messages
# 404가 아니면 프록시 없이 ANTHROPIC_BASE_URL=http://localhost:8000 직결 가능
```

## 7. 모델·타깃 추가 절차

### 7.1 기존 타깃에서 모델만 바꾸기

1. 해당 설정 파일에서 `MODEL`과 `SERVED_MODEL_NAME`을 바꾼다.
2. **VRAM 사전 점검이 꺼진다는 점을 안다.** 검사는 `MODEL`이 기본 문자열과 정확히 일치할 때만 돌기 때문에, 다른 모델로 바꾸면 VRAM 부족을 미리 잡아주지 않는다.
3. 파서 호환을 확인한다. 타깃 스크립트는 `--reasoning-parser qwen3`을 항상 붙이고, `ENABLE_TOOL_CALLS=1`이면 `--tool-call-parser qwen3_coder`도 붙인다. Qwen 계열이 아니면 이 두 값을 스크립트에서 바꿔야 한다.
4. 서버 재기동 후 클라이언트 설정도 갱신한다: `./install-codex-config.sh`, `./install-opencode-config.sh`.

### 7.2 새 하드웨어 타깃 추가

`targets/qwen38-27b-4090x2.sh`를 복사해 시작하는 것이 가장 가깝다. 체크리스트:

1. **`targets/<이름>.sh`** — 복사 후 아래를 고친다.
   - 상단 주석의 하드웨어·모델 설명
   - `ENV_FILE` 기본값을 `$SCRIPT_DIR/<이름>.env`로
   - `MODEL`, `SERVED_MODEL_NAME`, `PID_FILE`(`$REPO_ROOT/<고유이름>.pid`) 기본값
   - 메모리 관련 기본값 (`MAX_MODEL_LEN`, `MAX_NUM_SEQS`, `KV_CACHE_DTYPE`, `GPU_MEMORY_UTILIZATION`, `MAX_NUM_BATCHED_TOKENS`)
   - 사전 점검의 VRAM 임계값과 `MODEL` 문자열 일치 조건
   - compute capability 검사 유지/제거 여부
   - 에러 메시지 안의 스크립트 경로 (`VLLM_BIN=... ./targets/<이름>.sh`)
2. **`targets/<이름>.env.example`** — 같은 변수 집합을 주석과 함께.
3. **`.gitignore`** — `targets/<이름>.env`와 PID 파일 이름 규칙을 추가한다. 현재 `.gitignore`에 범용 `*.pid` 규칙이 **없으므로**(확인: `git check-ignore custom.pid` → 무출력) PID 파일 이름을 반드시 명시해야 한다.
4. **불변식 유지** — `set -euo pipefail`, `SCRIPT_DIR`/`REPO_ROOT` 해석 한 줄, `echo "$$" > "$PID_FILE"` 후 `exec ... "$@"`, 에러는 stderr에 원인+해결책 두 줄 후 `exit 1`.
5. **문법 검사** — `bash -n targets/<이름>.sh`.
6. **문서** — [targets.md](targets.md)에 절을 추가하고 [ARCHITECTURE.md](ARCHITECTURE.md) §3 흐름도에 노드를 더한다.

### 7.3 새 프로필 추가

`profiles/<이름>.env`를 만들기만 하면 된다. `use-profile.sh`가 디렉터리를 열거하므로 코드 수정이 필요 없다.

```
$ ./use-profile.sh --help
Usage: ./use-profile.sh <profile>

Available profiles:
  128k
  64k
```

프로필 파일은 `.env`를 **통째로 대체**하므로 `MODEL`부터 `CHAT_CHECK`까지 필요한 값을 모두 담아야 한다. `profiles/64k.env`(25줄)를 복사해 시작한다.

### 7.4 새 systemd 유닛 추가

현재 유닛은 Qwen3.6 전용이다. Qwen3.8용을 만들려면 `systemd/vllm-qwen36.service.in`을 복사해 `ExecStart` 경로를 바꾸고, `ExecStop`에 PID 파일을 넘긴다.

```ini
ExecStart=__WORKDIR__/targets/qwen38-27b-h100x2.sh
Environment=PID_FILE=__WORKDIR__/vllm-qwen38-h100x2.pid
ExecStop=__WORKDIR__/stop-vllm.sh
```

`Environment=`로 넘긴 값은 스크립트가 상속받은 환경이므로 `.env`보다 우선한다(§4.4). 설치는 `SERVICE_NAME=vllm-qwen38.service ./install-systemd-user.sh`인데, 현재 스크립트는 템플릿 경로가 `systemd/vllm-qwen36.service.in`으로 고정돼 있어 템플릿 파일을 바꾸거나 스크립트를 함께 수정해야 한다.

## 8. 문제 해결

### 8.1 사전 점검 에러 (run 스크립트가 즉시 중단)

| 메시지 | 원인 | 조치 |
|---|---|---|
| `ERROR: <경로> exists but is not readable by user '<계정>'.` | 설정 파일 권한. `use-profile.sh`가 `.env`를 `chmod 600`으로 만든다 | 소유자 계정으로 실행하거나 `chmod 644 .env` |
| `ERROR: 'vllm' executable not found.` | `PATH`에도 `<repo>/.venv/bin/vllm`에도 없음 | §2.1로 설치하거나 `VLLM_BIN=`으로 지정 |
| `ERROR: VLLM_BIN='...' does not exist or is not executable.` | 지정 경로가 틀림 | 경로 확인, `chmod +x` |
| `ERROR: nvidia-smi not found` | 드라이버 없음 / GPU 없는 머신 | GPU 서버에서 실행 |
| `ERROR: not enough GPUs: found N, need M` | GPU 개수 < `CUDA_VISIBLE_DEVICES` 항목 수 또는 < `TP_SIZE` | 둘을 실제 개수에 맞춘다 |
| `ERROR: CUDA_VISIBLE_DEVICES contains 'X' but this machine only has GPU indexes 0..N` | 존재하지 않는 인덱스 지정 | `nvidia-smi -L`로 확인 후 수정 |
| `ERROR: FP8 needs compute capability >= 8.9; the weakest selected GPU is smXX.` | Ampere 이하로 FP8 실행 시도 (qwen38-4090 타깃만 검사) | `qwen3-coder-2080ti/`의 llama.cpp 경로 사용 ([targets.md](targets.md#qwen3-coder-2080ti)) |
| `ERROR: not enough VRAM for <MODEL>: smallest selected GPU has N MiB` | VRAM 부족 | 더 작은 모델 또는 다른 머신. 임계값은 20,000 / 70,000 / 20,000 MiB |
| `ERROR: MODEL points to a local path that does not exist` | `/`·`./`로 시작하는 `MODEL` 경로가 없음 | 경로 수정 또는 HuggingFace ID 사용 |
| `ERROR: port N is already in use` | 다른 서버가 점유 | `./stop-vllm.sh` 또는 `PORT` 변경 |

### 8.2 경고 (진행은 됨)

| 메시지 | 의미 | 조치 |
|---|---|---|
| `WARNING: vLLM X detected; Qwen3.8 needs 0.17.0+` | 하이브리드 어텐션 미지원 가능 | `uv pip install -U vllm`. 버전 문자열이 `x.y.z`가 아니면 검사 자체를 건너뛴다 |
| `WARNING: /dev/shm is only N MiB; NCCL may fail` | 1 GiB 미만 | 컨테이너면 `--shm-size=2g` 등으로 키운다 |
| `WARNING: model not downloaded yet and only N GiB free` | 홈 디스크 여유 부족 | 공간 확보 또는 `HF_HOME`을 큰 디스크로 |

### 8.3 기동 이후

| 증상 | 원인 | 조치 |
|---|---|---|
| 기동 중 OOM | KV cache 예약 실패 | `MAX_MODEL_LEN`을 먼저 낮춘다(4090: `65536`→`32768`, H100: `262144`→`131072`). 다음이 `KV_CACHE_DTYPE=fp8`, 그다음이 `GPU_MEMORY_UTILIZATION=0.85` |
| `vLLM did not become ready within Ns.` | 모델 로딩/다운로드가 `WAIT_READY_SECONDS`보다 오래 걸림 | `WAIT_READY_SECONDS`를 늘린다. `.env`에 적거나 명령줄로 넘긴다(§4.4) |
| `chat completion failed.` + 404 본문 | 요청 모델명이 서버 서빙 이름과 다름 | `curl .../v1/models`로 실제 이름 확인. Qwen3.8 타깃이면 §5.2 |
| `health-check.sh`가 `chat completion OK`인데 아무것도 출력 안 함 | `max_tokens=16`을 thinking 출력이 소진해 `content`가 빔 | 정상 동작. 확인하려면 §5.2의 curl로 `max_tokens`를 늘려 본다 |
| 폴링 중 `curl: (7) Failed to connect` 반복 | `curl -fsS`의 `-S` 때문에 실패가 매번 stderr로 출력됨 | 정상. 준비되면 멈춘다 |
| `benchmark-smoke.sh`가 첫 케이스에서 끝나고 `GPU after`가 안 나옴 | `set -e` + `run_case`의 `return 1` | 원인은 첫 요청 실패. 서버·모델명을 먼저 확인 |
| 벤치마크가 `tok/s=n/a` | 응답에서 `completion_tokens`를 못 찾았거나 0 | 응답 본문을 직접 curl로 확인 |
| Codex가 `wire_api = "chat" is no longer supported` | 구버전 설정이 남음 | `./install-codex-config.sh` 재실행 |
| Codex 요청이 `/v1/responses`에서 404 | vLLM이 Responses API 미지원 | `uv pip install -U vllm`. 또는 OpenCode 사용(Chat Completions로 붙음) |
| `ERROR: could not parse existing <path>` | opencode.json이 깨진 JSON | JSON을 고치거나 파일을 옮기고 재실행. 스크립트는 아무것도 바꾸지 않았다 |
| `ERROR: python3 is required to safely merge JSON config.` | python3 없음 | 설치 후 재실행 |

### 8.4 종료

| 증상 | 원인 | 조치 |
|---|---|---|
| `No matching vLLM process found.` | 세 탐색 경로 모두 실패 | 정상(이미 죽음)일 수 있다. 실제로 남아 있다면 `nvidia-smi`로 PID를 찾아 직접 `kill` |
| `Some vLLM processes did not exit after Ns; sending SIGKILL` | SIGTERM 후 `TIMEOUT_SECONDS` 안에 안 죽음 | 정상 동작(GPU는 반환된다). 잦으면 `TIMEOUT_SECONDS`를 늘린다 |
| 의도한 서버가 아닌 다른 vLLM이 죽음 | 세 번째 탐색 경로가 `vllm`+`serve`+포트/모델명 부분 문자열로 매칭 | 같은 포트에 여러 타깃을 띄우지 않는다. 필요하면 `PORT`를 분리 |
| 종료 후에도 GPU 메모리가 안 돌아옴 | 자식 워커가 남음 | `nvidia-smi`로 잔여 PID 확인 후 `kill -9`. `stop-vllm.sh`는 `pgrep -P` 재귀로 자식을 수집하지만 부모와 끊긴 프로세스는 놓칠 수 있다 |

### 8.5 2080 Ti 구성

| 메시지 | 조치 |
|---|---|
| `BACKEND must be llama or vllm.` | `BACKEND=llama` 또는 `BACKEND=vllm` |
| `ERROR: llama-server not found: <경로>` | `./install-llama-cpp.sh` 실행 또는 `LLAMA_SERVER=` 지정 |
| `ERROR: GGUF model not found: <경로>` | `./download-gguf.sh` 실행 또는 `MODEL_PATH=` 지정 |
| `nvcc is required.` / `git is required.` / `cmake is required.` | CUDA Toolkit·git·cmake 설치 |
| `<경로> exists but is not a git checkout.` | `llama.cpp` 디렉터리를 지우거나 `LLAMA_CPP_DIR=`로 다른 경로 지정 |
| llama.cpp OOM | `LLAMA_CTX_SIZE=8192` → `LLAMA_TENSOR_SPLIT=0.45,0.55`(GPU 0이 화면 출력 담당) → KV cache `q4_0` 순 |
| vLLM OOM | `VLLM_MAX_MODEL_LEN=4096` |

## 9. 부작용 없는 확인 명령 모음

서버를 띄우지 않고 레포 상태만 점검할 때 쓴다. 아래는 모두 실제로 실행해 결과를 확인한 것들이다.

```bash
# 셸 문법 검사 (16개 전부 통과 확인됨)
for f in $(find . -name '*.sh' -not -path './.git/*'); do bash -n "$f" && echo "OK  $f"; done

# 프로필 목록
./use-profile.sh --help

# 사전 점검을 어디까지 통과하는지 (vllm 미설치면 1단계에서 멈춤 — GPU를 쓰지 않음)
./targets/qwen36-27b-4090x2.sh

# 종료 대상이 있는지만 확인 (없으면 아무것도 죽이지 않음)
./stop-vllm.sh

# 클라이언트 설정 생성 결과를 홈 대신 임시 경로로 미리 보기
CODEX_HOME=/tmp/codex-preview ./install-codex-config.sh
OPENCODE_CONFIG=/tmp/opencode-preview.json ./install-opencode-config.sh

# systemd 유닛이 어떤 내용으로 설치될지 (실제 설치는 하지 않음)
sed "s|__WORKDIR__|$PWD|g" systemd/vllm-qwen36.service.in

# .gitignore가 실제로 무엇을 막는지
git check-ignore -v .env vllm.pid vllm-qwen38-h100x2.pid custom.pid

# 서버가 떠 있을 때 실제 서빙 이름 확인
curl -fsS http://127.0.0.1:8000/v1/models | jq -r '.data[].id'
```

`./targets/*.sh`는 vLLM이 설치돼 있으면 실제로 서버를 띄우므로, 확인 목적이라면 vLLM이 없는 상태이거나 `VLLM_BIN=/bin/false`처럼 무해한 값을 줄 때만 안전하다.
