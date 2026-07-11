# vllm-setting

로컬 GPU에서 Qwen 계열 LLM을 OpenAI 호환 API로 서빙하기 위한 셸 스크립트 + 환경 프로필 모음입니다.

## 개요

이 레포는 개인용(1인 코딩 에이전트/IDE/CLI) 로컬 LLM 서버를 재현 가능하게 띄우기 위해 존재합니다. 두 가지 하드웨어 타깃을 다룹니다: 루트 디렉터리는 2x RTX 4090에서 `Qwen/Qwen3.6-27B-FP8`을 vLLM으로 서빙하는 기본 구성이고, `qwen3-coder-2080ti/`는 2x RTX 2080 Ti(11 GB x 2)에서 `Qwen3-Coder-30B-A3B-Instruct`를 llama.cpp(권장) 또는 vLLM(best-effort)으로 서빙하는 별도 구성입니다. 모든 튜닝 값은 `.env` 파일로 오버라이드할 수 있고, 스크립트 자체를 수정할 필요가 없도록 설계되어 있습니다.

## 주요 기능

### vLLM 서버 실행 (`run-qwen36-27b.sh`)

- `.env`가 있으면 로드한 뒤 `vllm serve`를 exec으로 실행합니다. 기본값: 모델 `Qwen/Qwen3.6-27B-FP8`, 서빙 이름 `qwen3.6-27b`, `PORT=8000`, `TP_SIZE=2`, `MAX_MODEL_LEN=65536`, `MAX_NUM_SEQS=1`.
- 1인 코딩용 플래그가 기본 적용됩니다: `--enable-prefix-caching`, `--enable-chunked-prefill`, `--disable-custom-all-reduce`, `--reasoning-parser qwen3`, `--language-model-only`(이미지 입력 미사용).
- `ENABLE_TOOL_CALLS=1`이면 `--enable-auto-tool-choice --tool-call-parser qwen3_coder`를 추가합니다.
- 시작 시 자신의 PID를 `vllm.pid`에 기록합니다.

### 안전한 종료 (`stop-vllm.sh`)

- `vllm.pid` → 포트 리스너(`ss`) → 프로세스 목록(`ps`) 순으로 vLLM 프로세스를 찾고, 자식 워커까지 재귀적으로 수집합니다.
- SIGTERM 후 `TIMEOUT_SECONDS`(기본 30초) 대기, 남으면 SIGKILL로 GPU 메모리를 확실히 반환합니다.

### 헬스 체크 (`health-check.sh`)

- `/v1/models`가 준비될 때까지(기본 최대 300초) 폴링한 뒤, 짧은 chat completion 요청까지 보내 실제 응답을 확인합니다.
- `CHAT_CHECK=0`이면 models 엔드포인트 확인만 수행합니다.

### 스모크 벤치마크 (`benchmark-smoke.sh`)

- 코딩 프롬프트 3종(binary-search, bug-review, lru-cache)을 순차 실행해 latency, completion token 수, 초당 토큰(tok/s)을 출력합니다.
- `nvidia-smi`가 있으면 실행 전후 GPU 메모리도 함께 표시합니다. `BENCH_MAX_TOKENS`로 생성 토큰 수 조절.

### 실행 프로필 전환 (`use-profile.sh` + `profiles/`)

- `profiles/64k.env`(안정 기본값), `profiles/128k.env`(롱 컨텍스트)를 `.env`로 복사해 활성화합니다.
- 기존 `.env`는 타임스탬프 백업(`.env.backup.*`) 후 교체하고, 새 `.env`는 `chmod 600` 처리합니다.

### systemd user 서비스 (`install-systemd-user.sh` + `systemd/`)

- `systemd/vllm-qwen36.service.in` 템플릿의 `__WORKDIR__`을 현재 체크아웃 경로로 치환해 `~/.config/systemd/user/vllm-qwen36.service`로 설치하고 enable까지 수행합니다.
- 서비스는 `ExecStart`에 run 스크립트, `ExecStop`에 stop 스크립트를 사용하며 `Restart=on-failure`입니다.

### 2080 Ti 서브 구성 (`qwen3-coder-2080ti/`)

- `install-llama-cpp.sh`: llama.cpp를 clone하고 CUDA(SM 7.5)로 `llama-server`/`llama-cli`를 빌드합니다.
- `download-gguf.sh`: `unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF`에서 GGUF(기본 `Q4_K_S`, 약 17.5 GB)를 이어받기 지원으로 다운로드합니다.
- `run-llama-server.sh`: 기본 `http://127.0.0.1:8080/v1`, 컨텍스트 16K, KV cache `q8_0`, layer split으로 llama-server를 실행합니다.
- `run-vllm-server.sh`: 4-bit AWQ 체크포인트(`cyankiwi/Qwen3-Coder-30B-A3B-Instruct-AWQ-4bit`), 8K 컨텍스트, TP=2 + expert parallel의 best-effort vLLM 대안 경로입니다.
- `health-check.sh`(`BACKEND=llama|vllm` 선택), `stop-server.sh`(두 백엔드의 PID 파일 기반 종료)를 제공합니다.

## 코드 구성

```text
vllm-setting/
├── run-qwen36-27b.sh          # vLLM 실행 (2x 4090, Qwen3.6-27B-FP8)
├── stop-vllm.sh               # vLLM 프로세스 트리 종료 및 GPU 반환
├── health-check.sh            # /v1/models + chat completion 확인
├── benchmark-smoke.sh         # 코딩 프롬프트 3종 성능 스모크 테스트
├── use-profile.sh             # profiles/*.env를 .env로 활성화(백업 포함)
├── install-systemd-user.sh    # systemd --user 서비스 설치
├── .env.example               # 루트 구성 설정 예시
├── profiles/
│   ├── 64k.env                # 안정 기본 프로필 (MAX_MODEL_LEN=65536)
│   └── 128k.env               # 롱 컨텍스트 프로필 (MAX_MODEL_LEN=131072)
├── systemd/
│   └── vllm-qwen36.service.in # systemd user 서비스 템플릿
└── qwen3-coder-2080ti/        # 2x RTX 2080 Ti용 별도 구성
    ├── install-llama-cpp.sh   # llama.cpp CUDA 빌드 (SM 7.5)
    ├── download-gguf.sh       # GGUF 모델 다운로드 (기본 Q4_K_S)
    ├── run-llama-server.sh    # llama-server 실행 (권장 경로)
    ├── run-vllm-server.sh     # vLLM 실행 (대안 경로, AWQ 4-bit)
    ├── health-check.sh        # BACKEND=llama|vllm 헬스 체크
    ├── stop-server.sh         # PID 파일 기반 서버 종료
    └── .env.example           # 2080 Ti 구성 설정 예시
```

`.env`, `vllm.pid`, 모델 파일, llama.cpp 체크아웃 등은 `.gitignore`로 Git에서 제외됩니다.

## 설계

핵심 패턴은 "설정은 `.env`, 로직은 스크립트"입니다. 모든 스크립트는 시작 시 같은 디렉터리의 `.env`를 `set -a`로 로드하고, 각 변수에 `${VAR:-default}` 기본값을 두므로 `.env` 없이도 동작합니다. 프로필 전환은 파일 복사(`use-profile.sh`)로 처리하고, 서버 수명 관리는 PID 파일 + 포트/프로세스 탐색의 이중 안전장치로 처리합니다. systemd 서비스는 run/stop 스크립트를 그대로 감싸므로 수동 실행과 서비스 실행이 동일한 코드 경로를 탑니다.

```mermaid
flowchart TD
    P64["profiles/64k.env"] --> UP["use-profile.sh"]
    P128["profiles/128k.env"] --> UP
    EX[".env.example (cp)"] --> ENV[".env"]
    UP --> ENV
    ENV --> RUN["run-qwen36-27b.sh"]
    ENV --> STOP["stop-vllm.sh"]
    ENV --> HC["health-check.sh"]
    ENV --> BM["benchmark-smoke.sh"]
    SYSD["systemd --user 서비스<br/>(install-systemd-user.sh)"] -->|ExecStart| RUN
    SYSD -->|ExecStop| STOP
    RUN -->|vllm serve| API["OpenAI 호환 API<br/>http://localhost:8000/v1"]
    RUN -->|PID 기록| PID["vllm.pid"]
    PID --> STOP
    HC -->|/v1/models + chat| API
    BM -->|/v1/chat/completions| API
    CLI["코딩 에이전트 / IDE / OpenAI SDK"] --> API
```

`qwen3-coder-2080ti/`도 같은 패턴을 따르되, 백엔드가 llama.cpp(기본, 포트 8080)와 vLLM(대안, 포트 8000) 두 갈래이고 `health-check.sh`가 `BACKEND` 변수로 대상을 선택합니다.

## 실행 방법

### 설치 (vLLM이 없는 경우)

별도 Python 가상환경에서 설치합니다.

```bash
uv venv
source .venv/bin/activate
uv pip install -U vllm --torch-backend=auto
```

`uv`를 쓰지 않는 환경이면 `pip install -U vllm`로 설치해도 됩니다.

### 최초 설정

```bash
cd /home/kms/dev/vllm-setting
cp .env.example .env
chmod +x *.sh
```

필요하면 `.env`에서 GPU 번호(`CUDA_VISIBLE_DEVICES`), 포트(`PORT`), 컨텍스트 길이(`MAX_MODEL_LEN`)를 수정합니다. 프로필을 바로 쓰려면:

```bash
./use-profile.sh 64k    # 안정 기본값 (65536)
./use-profile.sh 128k   # 롱 컨텍스트 (131072)
```

### 시작 / 확인 / 종료

```bash
./run-qwen36-27b.sh     # 서버 시작 → http://localhost:8000/v1, 모델명 qwen3.6-27b
./health-check.sh       # /v1/models 대기 후 chat completion 확인 (CHAT_CHECK=0으로 생략 가능)
./benchmark-smoke.sh    # 스모크 벤치마크 (BENCH_MAX_TOKENS=1024 등으로 조절)
./stop-vllm.sh          # 종료 후 nvidia-smi로 GPU 메모리 반환 확인
```

OpenAI SDK 호환 클라이언트 연결 예시:

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:8000/v1", api_key="EMPTY")
response = client.chat.completions.create(
    model="qwen3.6-27b",
    messages=[{"role": "user", "content": "Write a concise Python binary search function."}],
    temperature=0.6,
    top_p=0.95,
    max_tokens=2048,
)
print(response.choices[0].message.content)
```

### systemd user 서비스

터미널을 닫아도 서버를 유지하려면:

```bash
./install-systemd-user.sh
systemctl --user start vllm-qwen36.service

# 상태/로그
systemctl --user status vllm-qwen36.service
journalctl --user -u vllm-qwen36.service -f

# 재시작/종료
systemctl --user restart vllm-qwen36.service
systemctl --user stop vllm-qwen36.service
```

부팅 후 자동 시작에는 환경에 따라 linger가 필요할 수 있습니다: `loginctl enable-linger "$USER"`.

### 2080 Ti 구성 (qwen3-coder-2080ti/)

권장 경로(llama.cpp) — Git, CMake, CUDA Toolkit(`nvcc`), C/C++ 빌드 도구, curl 필요:

```bash
cd qwen3-coder-2080ti
cp .env.example .env
chmod +x *.sh
./install-llama-cpp.sh
./download-gguf.sh
./run-llama-server.sh            # http://127.0.0.1:8080/v1, 모델명 qwen3-coder-30b-a3b (포그라운드)
BACKEND=llama ./health-check.sh  # 다른 터미널에서
./stop-server.sh
```

품질을 우선하고 16K 이하 컨텍스트를 쓸 경우:

```bash
GGUF_QUANT=Q4_K_M ./download-gguf.sh
MODEL_PATH="$PWD/models/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf" \
  LLAMA_CTX_SIZE=16384 ./run-llama-server.sh
```

대안 경로(vLLM, best-effort):

```bash
cd qwen3-coder-2080ti
python3 -m venv .venv-vllm
source .venv-vllm/bin/activate
pip install -U pip vllm
./run-vllm-server.sh
BACKEND=vllm ./health-check.sh
```

OOM이면 llama.cpp는 `LLAMA_CTX_SIZE=8192` → `LLAMA_TENSOR_SPLIT=0.45,0.55`(GPU 0이 화면 출력을 담당할 때) → KV cache `q4_0` 순으로, vLLM은 `VLLM_MAX_MODEL_LEN=4096`으로 낮춥니다.

## 컨텍스트 튜닝 노트

- 기본 `MAX_MODEL_LEN=65536`은 2x24GB에서 안정성을 우선한 값입니다. 1인 사용이므로 `MAX_NUM_SEQS=1`로 KV cache를 한 세션에 몰아줍니다.
- Qwen3.6-27B는 하이브리드 어텐션(레이어 4개 중 1개만 full attention)이라 KV cache가 토큰당 약 64KB로 작아, 128K도 bf16 KV(`KV_CACHE_DTYPE=auto`) 그대로 여유 있게 들어갑니다. `fp8` KV는 이 모델에서는 메모리상 불필요하고 품질을 약간 깎을 수 있어 쓰지 않습니다.
- OOM이 나면 `MAX_MODEL_LEN`을 `98304` 또는 `65536`으로 낮추는 쪽이 가장 효과적입니다.
- `--enable-prefix-caching`: 같은 repo/context를 반복 투입하는 코딩 에이전트 워크로드에 유리합니다.
- `--disable-custom-all-reduce`: NVLink 없는 4090 2장 환경에서 안정성을 우선합니다.
- `ENABLE_TOOL_CALLS=1`: OpenAI tool calling을 vLLM parser(`qwen3_coder`)로 처리하고 싶을 때만 켭니다.
- 2080 Ti는 Turing(SM 7.5)이므로 FP8 모델을 사용하지 않습니다. 외부 접근이 필요할 때만 `HOST=0.0.0.0`으로 바꾸고 방화벽/리버스 프록시 인증을 함께 설정합니다.
