# vLLM Setting for Qwen3.6-27B

2x RTX 4090에서 `Qwen3.6-27B`를 1인 코딩용으로 돌리는 설정입니다.

- 기본 모델: `Qwen/Qwen3.6-27B-FP8`
- GPU 구성: 2장 tensor parallel
- 사용 패턴: 1인 코딩 에이전트/IDE/CLI
- 이미지 입력: 사용 안 함, `--language-model-only`
- 기본 컨텍스트: `65536`
- 기본 API: OpenAI-compatible `http://localhost:8000/v1`

## Files

```text
run-qwen36-27b.sh  # vLLM 실행
stop-vllm.sh       # vLLM 종료 및 GPU 자원 반환
.env.example       # 설정 예시
README.md          # 사용 방법
```

## Install

vLLM이 없다면 별도 Python 가상환경에서 설치하세요.

```bash
uv venv
source .venv/bin/activate
uv pip install -U vllm --torch-backend=auto
```

`uv`를 쓰지 않는 환경이면 `pip install -U vllm`로 설치해도 됩니다.

## First Setup

```bash
cd /home/kms/dev/vllm-setting
cp .env.example .env
chmod +x run-qwen36-27b.sh stop-vllm.sh
```

필요하면 `.env`에서 GPU 번호, 포트, 컨텍스트 길이를 수정합니다.

```bash
CUDA_VISIBLE_DEVICES=0,1
PORT=8000
MAX_MODEL_LEN=65536
```

## Start

```bash
cd /home/kms/dev/vllm-setting
./run-qwen36-27b.sh
```

서버가 올라오면 다음 endpoint를 씁니다.

```text
http://localhost:8000/v1
```

클라이언트 모델명은 기본값 기준으로 다음입니다.

```text
qwen3.6-27b
```

## Client Example

OpenAI SDK 호환 클라이언트에서는 이렇게 연결합니다.

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:8000/v1",
    api_key="EMPTY",
)

response = client.chat.completions.create(
    model="qwen3.6-27b",
    messages=[
        {"role": "user", "content": "Write a concise Python binary search function."}
    ],
    temperature=0.6,
    top_p=0.95,
    max_tokens=2048,
)

print(response.choices[0].message.content)
```

## Stop

```bash
cd /home/kms/dev/vllm-setting
./stop-vllm.sh
```

`stop-vllm.sh`는 `vllm.pid`를 우선 사용하고, 필요하면 `PORT=8000`에서 듣는 vLLM 프로세스를 찾아 child worker까지 종료합니다.

종료 뒤 GPU 메모리가 반환됐는지 확인합니다.

```bash
nvidia-smi
```

## Context Tuning

기본 `MAX_MODEL_LEN=65536`은 2x24GB에서 안정성을 우선한 값입니다. 1인 사용이므로 `MAX_NUM_SEQS=1`로 두어 KV cache를 한 세션에 몰아줍니다.

일반 코딩 작업:

```bash
MAX_MODEL_LEN=65536
KV_CACHE_DTYPE=auto
GPU_MEMORY_UTILIZATION=0.90
MAX_NUM_SEQS=1
```

큰 repo 작업에서 더 긴 컨텍스트가 필요하면 `.env`에서 먼저 이렇게 올려 보세요.

```bash
MAX_MODEL_LEN=98304
GPU_MEMORY_UTILIZATION=0.92
```

128K가 필요하면 KV cache dtype을 줄이는 설정을 같이 테스트하세요.

```bash
MAX_MODEL_LEN=131072
KV_CACHE_DTYPE=fp8
GPU_MEMORY_UTILIZATION=0.95
```

OOM이 나면 `MAX_MODEL_LEN`을 `98304` 또는 `65536`으로 낮추는 쪽이 가장 효과적입니다.

## Tool Calling

기본은 일반 코딩 채팅/에이전트 사용을 위해 tool parser를 끕니다.

vLLM의 OpenAI tool calling parser를 쓰고 싶을 때만 `.env`에서 켭니다.

```bash
ENABLE_TOOL_CALLS=1
```

## Notes

- `MAX_NUM_SEQS=1`: 1인 사용 기준. 동시 요청을 거의 받지 않도록 해서 KV cache를 한 세션에 몰아줍니다.
- `--enable-prefix-caching`: 코딩 에이전트처럼 같은 repo/context를 반복해서 넣는 워크로드에 유리합니다.
- `--disable-custom-all-reduce`: NVLink 없는 4090 2장 환경에서 안정성을 우선합니다.
- `ENABLE_TOOL_CALLS=1`: OpenAI tool calling을 vLLM parser로 처리하고 싶을 때만 켜세요.
