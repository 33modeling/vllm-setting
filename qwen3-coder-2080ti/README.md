# Qwen3-Coder on 2x RTX 2080 Ti

`Qwen3-Coder-30B-A3B-Instruct`를 RTX 2080 Ti 11 GB 두 장에서 구동하는 설정이다. 총 VRAM은 22 GB지만 실행 버퍼와 KV cache 공간이 필요하므로 llama.cpp의 `Q4_K_S`를 기본값으로 사용한다.

## 권장 경로: llama.cpp

필수 패키지는 Git, CMake, CUDA Toolkit(`nvcc`), C/C++ 빌드 도구, curl이다.

```bash
cd qwen3-coder-2080ti
cp .env.example .env
chmod +x *.sh
./install-llama-cpp.sh
./download-gguf.sh
./run-llama-server.sh
```

기본 API는 `http://127.0.0.1:8080/v1`, 모델명은 `qwen3-coder-30b-a3b`이다. 서버는 포그라운드로 실행된다.

다른 터미널에서 확인한다.

```bash
BACKEND=llama ./health-check.sh
```

기본 모델은 약 17.5 GB인 `Q4_K_S`다. 품질을 조금 더 우선하고 16K 이하 컨텍스트를 쓸 경우 다음처럼 약 18.6 GB인 `Q4_K_M`을 받을 수 있다.

```bash
GGUF_QUANT=Q4_K_M ./download-gguf.sh
MODEL_PATH="$PWD/models/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf" \
  LLAMA_CTX_SIZE=16384 ./run-llama-server.sh
```

OOM이면 `.env`에서 다음 순서로 조정한다.

1. `LLAMA_CTX_SIZE=8192`
2. 화면 출력에 GPU 0을 쓰면 `LLAMA_TENSOR_SPLIT=0.45,0.55`
3. KV cache를 `q4_0`으로 낮춘다.

## 대안 경로: vLLM

vLLM의 Turing 4-bit 지원을 이용한 best-effort 설정이다. 이 VRAM 용량에서는 llama.cpp가 더 예측 가능하며, vLLM은 버전과 양자화 체크포인트에 따라 시작하지 못할 수 있다.

```bash
cd qwen3-coder-2080ti
python3 -m venv .venv-vllm
source .venv-vllm/bin/activate
pip install -U pip vllm
./run-vllm-server.sh
```

기본값은 4-bit AWQ 계열 체크포인트, 8K context, 단일 동시 요청, TP=2 + expert parallel이다. 확인은 다음과 같다.

```bash
BACKEND=vllm ./health-check.sh
```

OOM이면 `VLLM_MAX_MODEL_LEN=4096`으로 낮춘다. vLLM 서버는 모델을 Hugging Face 캐시에 자동 다운로드하므로 최초 실행에는 충분한 디스크 공간과 시간이 필요하다.

## 종료

관리 스크립트로 직접 실행한 서버를 종료한다.

```bash
./stop-server.sh
```

## 운영 참고

- 2080 Ti는 Turing(SM 7.5)이므로 FP8 모델을 사용하지 않는다.
- NVLink가 없어도 layer/tensor parallel은 가능하다. NVLink가 있으면 카드 간 전송 병목이 줄어든다.
- 외부 접근이 필요할 때만 `HOST=0.0.0.0`으로 바꾸고 방화벽 또는 리버스 프록시 인증을 함께 설정한다.
- 이 디렉터리의 `.env`, 모델, llama.cpp checkout, PID 파일은 Git에서 제외된다.
