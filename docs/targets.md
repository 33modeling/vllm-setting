# 서빙 타깃

하드웨어 구성 하나가 실행 스크립트 하나에 대응합니다. 쓰려는 구성의 절만 읽으면 됩니다.

| 타깃 | 하드웨어 | 모델 | 실행 |
|---|---|---|---|
| [qwen36-27b-4090x2](#qwen36-27b-4090x2) | 2x RTX 4090 (24GB x2) | `Qwen/Qwen3.6-27B-FP8` | `./targets/qwen36-27b-4090x2.sh` |
| [qwen38-27b-h100x2](#qwen38-27b-h100x2) | 2x H100 (80GB x2) | `Qwen/Qwen3.8-27B` (BF16) | `./targets/qwen38-27b-h100x2.sh` |
| [qwen38-27b-4090x2](#qwen38-27b-4090x2) | 2x RTX 4090 (24GB x2) | `Qwen/Qwen3.8-27B-FP8` | `./targets/qwen38-27b-4090x2.sh` |
| [qwen3-coder-2080ti](#qwen3-coder-2080ti) | 2x RTX 2080 Ti (11GB x2) | `Qwen3-Coder-30B-A3B-Instruct` GGUF | `qwen3-coder-2080ti/run-llama-server.sh` |

세 vLLM 타깃은 모두 `http://localhost:8000/v1`에 OpenAI 호환 API를 엽니다. 서빙 이름만 다릅니다.

## 공통 준비

vLLM이 없으면 레포 안 가상환경에 설치합니다. 세 스크립트 모두 `PATH` → 레포 루트 `.venv/bin/vllm` 순으로 찾습니다.

```bash
uv venv
source .venv/bin/activate
uv pip install -U vllm --torch-backend=auto
```

다른 위치의 vLLM을 쓰려면 `VLLM_BIN=/경로/bin/vllm`으로 지정합니다.

> ⚠️ **설정 파일은 Git에 올라가지 않는 머신별 로컬 파일입니다.** clone한 머신마다 그 머신 사양에 맞게 새로 잡아야 합니다. 안 맞는 채로 실행하면 사전 점검이 어느 항목이 문제인지 에러로 알려줍니다.

## 모든 타깃 공통: 사전 점검

세 스크립트 모두 실행 전에 아래를 확인하고, 하나라도 안 맞으면 원인과 해결 방법을 출력한 뒤 중단합니다.

1. **vllm 실행파일** — `VLLM_BIN` → `PATH` → 레포 루트 `.venv/bin/vllm` 순 탐색
2. **GPU** — 드라이버 존재, 개수가 `TP_SIZE`를 만족하는지, `CUDA_VISIBLE_DEVICES`의 번호가 실제 존재하는지
3. **VRAM** — 해당 모델이 GPU당 요구량을 만족하는지
4. **MODEL** — 로컬 경로일 때 존재 여부 (HuggingFace ID면 첫 실행에 자동 다운로드)
5. **포트** — 이미 사용 중인지

Qwen3.8 타깃 두 개는 여기에 두 가지가 더 붙습니다.

6. **vLLM 버전** — Qwen3.8은 하이브리드 어텐션이라 `0.17.0+`가 필요합니다. 낮으면 경고 후 진행(nightly 버전 문자열이 다양해서 차단하지는 않음)
7. **compute capability** — FP8은 `8.9+`가 필요합니다. 4090 타깃에서 Ampere 이하면 중단하고 llama.cpp 경로를 안내

경고만 내는 항목: `/dev/shm`이 작을 때(NCCL 실패 위험), 모델 미다운로드 상태에서 디스크 여유가 부족할 때.

---

## qwen36-27b-4090x2

**`Qwen/Qwen3.6-27B-FP8` @ 2x RTX 4090** — 레포의 기본 구성. 1인 코딩 에이전트용.

| 항목 | 값 |
|---|---|
| 설정 파일 | 레포 루트 `.env` (공유) |
| 서빙 이름 | `qwen3.6-27b-fp8` |
| `MAX_MODEL_LEN` | `65536` |
| `KV_CACHE_DTYPE` | `auto` (bf16) |
| `MAX_NUM_SEQS` | `2` |
| PID 파일 | `vllm.pid` |

```bash
cp .env.example .env
./targets/qwen36-27b-4090x2.sh   # 시작
./health-check.sh                # 확인
./stop-vllm.sh                   # 종료
```

프로필로 컨텍스트 길이를 바꿀 수 있습니다.

```bash
./use-profile.sh 64k     # 안정 기본값 (65536)
./use-profile.sh 128k    # 롱 컨텍스트 (131072)
```

기본 적용되는 플래그: `--enable-prefix-caching`, `--enable-chunked-prefill`, `--disable-custom-all-reduce`, `--reasoning-parser qwen3`, `--language-model-only`(이미지 입력 미사용), 그리고 tool calling(`--enable-auto-tool-choice --tool-call-parser qwen3_coder`).

이 타깃만 **공유 `.env`를 읽습니다.** `use-profile.sh`와 두 installer(`install-codex-config.sh`, `install-opencode-config.sh`)가 같은 파일을 보기 때문입니다.

---

## qwen38-27b-h100x2

**`Qwen/Qwen3.8-27B` (BF16) @ 2x H100 80GB** — 160GB면 무양자화 원본(~54GB)이 그대로 들어가므로 양자화하지 않고 네이티브 전체 컨텍스트로 띄웁니다. 다중 사용자 기본값.

| 항목 | 값 | 이유 |
|---|---|---|
| 설정 파일 | `targets/qwen38-27b-h100x2.env` | 공유 `.env`를 읽지 않음 |
| 서빙 이름 | `qwen3.8-27b` | |
| `MAX_MODEL_LEN` | `262144` | 네이티브 전체 컨텍스트 |
| `KV_CACHE_DTYPE` | `fp8` | 262K x 동시 16세션을 감당하려면 필요 |
| `MAX_NUM_SEQS` | `16` | 다중 사용자 |
| `DISABLE_CUSTOM_ALL_REDUCE` | `0` | NVLink가 있어 custom all-reduce가 빠른 경로 |
| `LANGUAGE_MODEL_ONLY` | `0` | VRAM 여유가 있어 이미지 입력 유지 |
| PID 파일 | `vllm-qwen38-h100x2.pid` | |

```bash
cp targets/qwen38-27b-h100x2.env.example targets/qwen38-27b-h100x2.env   # 선택 (없어도 동작)
./targets/qwen38-27b-h100x2.sh
PORT=8000 SERVED_MODEL_NAME=qwen3.8-27b ./health-check.sh
PID_FILE=./vllm-qwen38-h100x2.pid PORT=8000 ./stop-vllm.sh
```

`ENABLE_MTP=1`로 MTP draft head 투기적 디코딩을 켤 수 있습니다. 저동시성 지연에만 도움이 되고 체크포인트에 speculative 모듈이 있어야 하므로 **기본은 off**입니다 — 켠 뒤 `./benchmark-smoke.sh`로 실제 이득을 확인하세요.

262,144를 넘기려면 `VLLM_ALLOW_LONG_MAX_MODEL_LEN=1`과 YaRN 스케일링이 필요합니다(최대 1M).

---

## qwen38-27b-4090x2

**`Qwen/Qwen3.8-27B-FP8` @ 2x RTX 4090** — 48GB에는 BF16(~54GB)이 안 들어가므로 공식 block-wise FP8을 씁니다. 가중치 ~28GB → TP=2로 14GB/GPU, 나머지 약 15GB가 KV 몫입니다.

| 항목 | 값 | 이유 |
|---|---|---|
| 설정 파일 | `targets/qwen38-27b-4090x2.env` | 공유 `.env`를 읽지 않음 |
| 서빙 이름 | `qwen3.8-27b-fp8` | |
| `MAX_MODEL_LEN` | `65536` | 안정 기본값. 131072도 대체로 들어감 |
| `KV_CACHE_DTYPE` | `auto` (bf16) | 4층 중 1층만 KV가 자라서 65536은 bf16으로 충분 — fp8의 품질 손해를 피함 |
| `MAX_NUM_SEQS` | `2` | 1인 코딩 + 백그라운드 요청 |
| `DISABLE_CUSTOM_ALL_REDUCE` | `1` | NVLink 없음 |
| `LANGUAGE_MODEL_ONLY` | `1` | vision tower를 떼서 VRAM 확보 |
| PID 파일 | `vllm-qwen38-4090x2.pid` | |

```bash
cp targets/qwen38-27b-4090x2.env.example targets/qwen38-27b-4090x2.env   # 선택 (없어도 동작)
./targets/qwen38-27b-4090x2.sh
PORT=8000 SERVED_MODEL_NAME=qwen3.8-27b-fp8 ./health-check.sh
PID_FILE=./vllm-qwen38-4090x2.pid PORT=8000 ./stop-vllm.sh
```

**왜 FP8뿐인가** — 2026-08 기준 Qwen3.8-27B의 vLLM용 양자화는 공식 FP8이 사실상 유일합니다.

- FP8 block-wise는 compute capability `8.9+`를 요구하고 Ada(4090)가 정확히 `8.9`라 네이티브로 돕니다. Ampere 이하는 불가 — 사전 점검이 막습니다.
- NVFP4 / NVFP4A16은 대안이 못 됩니다. MLP만 4bit이라 디스크가 28.8 GiB로 FP8과 거의 같고, 네이티브 FP4 GEMM은 Blackwell(SM100+) 전용이라 4090에서는 런타임 역양자화로 더 느립니다.
- AWQ / GPTQ 4-bit 커뮤니티 양자화는 Qwen3.6-27B에만 있고 3.8용은 아직 없습니다. 더 가볍게 가야 한다면 Qwen3.6-27B 4bit으로 내려가는 선택지가 됩니다.

### Qwen3.8-27B 모델 특성 (두 타깃 공통)

- **하이브리드 어텐션** — 64개 층 중 48개가 linear attention. 이 아키텍처 지원 때문에 vLLM `0.17.0` 이상이 필요합니다.
- KV cache가 자라는 층은 **4개 중 1개뿐**이라 컨텍스트를 크게 잡아도 KV가 먼저 터지지 않습니다.
- **네이티브 VLM**(이미지·비디오). 텍스트만 쓰면 `LANGUAGE_MODEL_ONLY=1`로 vision tower를 떼서 VRAM을 아낍니다.
- thinking이 기본 ON이고 `reasoning_effort`(low/medium/xhigh)로 조절합니다. 파서는 Qwen3.6과 동일하게 `--reasoning-parser qwen3` + `--tool-call-parser qwen3_coder`.

### OOM 대처

`MAX_MODEL_LEN`을 `32768`로 낮추는 것이 가장 효과적입니다. 그 다음이 `KV_CACHE_DTYPE=fp8`, 그 다음이 `GPU_MEMORY_UTILIZATION`을 `0.85`로 낮추는 순서입니다. 반대로 131072로 올릴 때는 `KV_CACHE_DTYPE=fp8`을 함께 켜세요.

---

## qwen3-coder-2080ti

**`Qwen3-Coder-30B-A3B-Instruct` @ 2x RTX 2080 Ti (11GB x2)** — 유일하게 vLLM이 아닌 별도 구성입니다. Turing(SM 7.5)이라 FP8을 못 쓰므로 llama.cpp + GGUF가 권장 경로이고, 포트도 8080으로 다릅니다.

`qwen3-coder-2080ti/` 안에 자체 스크립트 일습이 들어 있습니다.

- `install-llama-cpp.sh` — llama.cpp를 clone하고 CUDA(SM 7.5)로 `llama-server`/`llama-cli` 빌드
- `download-gguf.sh` — `unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF`에서 GGUF(기본 `Q4_K_S`, 약 17.5GB) 이어받기 다운로드
- `run-llama-server.sh` — `http://127.0.0.1:8080/v1`, 컨텍스트 16K, KV cache `q8_0`, layer split
- `run-vllm-server.sh` — 4-bit AWQ(`cyankiwi/Qwen3-Coder-30B-A3B-Instruct-AWQ-4bit`), 8K 컨텍스트, TP=2 + expert parallel의 best-effort 대안
- `health-check.sh`(`BACKEND=llama|vllm`), `stop-server.sh`

### 권장 경로 (llama.cpp)

Git, CMake, CUDA Toolkit(`nvcc`), C/C++ 빌드 도구, curl 필요:

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

### 대안 경로 (vLLM, best-effort)

```bash
cd qwen3-coder-2080ti
python3 -m venv .venv-vllm
source .venv-vllm/bin/activate
pip install -U pip vllm
./run-vllm-server.sh
BACKEND=vllm ./health-check.sh
```

### OOM 대처

- llama.cpp: `LLAMA_CTX_SIZE=8192` → `LLAMA_TENSOR_SPLIT=0.45,0.55`(GPU 0이 화면 출력을 담당할 때) → KV cache `q4_0` 순으로 낮춥니다.
- vLLM: `VLLM_MAX_MODEL_LEN=4096`으로 낮춥니다.

이 서버에 Codex를 붙이려면 [agents.md](agents.md)의 "환경 변수로 설정 바꾸기 > 방법 B"를 참고하세요.
