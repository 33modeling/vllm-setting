# Qwen3.6-35B-A3B Uncensored on 2x RTX 4090

`HauhauCS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive`(Qwen3.6-35B-A3B의 uncensored 변형)를 RTX 4090 24 GB 두 장에서 llama.cpp로 구동하는 설정이다. 기본 양자화는 `Q6_K_P`(~31 GB)로, 두 장에 나눠 올리면 128K 컨텍스트까지 여유가 있다.

## 왜 llama.cpp인가 (vLLM 불가?)

- 원본 레포는 **GGUF 파일만 배포**한다 (safetensors 없음). `Q6_K_P` 같은 K_P 양자화는 HauhauCS 커스텀 포맷이지만 llama.cpp·LM Studio 등 GGUF 런타임과 완전 호환된다.
- vLLM의 GGUF 지원은 공식 문서 기준 "highly experimental + under-optimized"이고 별도 플러그인(`vllm-gguf-plugin`)으로 분리됐다. 신형 하이브리드 MoE 아키텍처 + 커스텀 양자화 조합이라 현실적으로 vLLM으로는 이 GGUF를 못 돌린다.
- vLLM으로 꼭 서빙하려면 GGUF가 아니라 서드파티 safetensors 변형(`lamianlbe/...-fp8`, ~37.5 GB)을 받아야 하는데, 2x24 GB에서 가중치만 36.6 GB라 KV cache 여유가 거의 없어 권장하지 않는다.

## 실행

필수 패키지는 Git, CMake, CUDA Toolkit(`nvcc`), C/C++ 빌드 도구, curl이다.

```bash
cd qwen36-35b-uncensored
cp .env.example .env
chmod +x *.sh
./install-llama-cpp.sh     # llama.cpp CUDA 빌드 (SM 8.9)
./download-gguf.sh         # Q6_K_P (~31 GB) 다운로드 — 이미 받았다면 MODEL_PATH로 지정
./run-llama-server.sh      # http://127.0.0.1:8080/v1, 모델명 qwen3.6-35b-uncensored (포그라운드)
```

이미 다른 경로에 GGUF를 받아뒀다면 다시 받을 필요 없이 `.env`에 경로만 지정한다.

```bash
# .env
MODEL_PATH=/path/to/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-Q6_K_P.gguf
```

다른 터미널에서 확인한다.

```bash
./health-check.sh
./stop-server.sh   # 종료
```

## 루트 vLLM 서버와의 공존

**같은 2x 4090을 쓰므로 27B vLLM 서버와 동시에 못 띄운다.** vLLM은 GPU 메모리의 90%를 선점하므로, 이 서버를 띄우기 전에 먼저 내려야 한다.

```bash
../stop-vllm.sh   # 또는 systemctl --user stop vllm-qwen36.service
```

run 스크립트가 시작 전에 GPU 여유 메모리를 확인해서, vLLM이 떠 있으면 원인과 함께 중단한다(`SKIP_VRAM_CHECK=1`로 생략 가능). 포트도 vLLM(8000)과 다른 8080을 쓴다.

## 모델 특성

- 35B 총 파라미터, 토큰당 ~3B 활성(MoE, 256 experts 중 8 라우팅), 네이티브 262K 컨텍스트.
- **thinking 모델**이다. 모델 카드 권장에 따라 컨텍스트 기본값을 128K(`LLAMA_CTX_SIZE=131072`)로 잡았다 — 128K 미만이면 thinking 품질이 떨어진다고 명시돼 있다.
- 하이브리드 어텐션(linear:full = 3:1)이라 KV cache가 작아 128K도 f16 KV로 들어간다. Q6 가중치 ~15.3 GB/장 + KV·버퍼로 장당 ~19 GB 선.
- 샘플링 기본값은 Qwen 공식 coding/precise 프로필(temp 0.6, top_p 0.95, top_k 20, min_p 0). 일반 대화 위주면 `LLAMA_TEMP=1.0`.
- 멀티모달(vision) 모델이지만 텍스트 서빙에는 mmproj가 필요 없다. 이미지 입력을 쓰려면 `DOWNLOAD_MMPROJ=1 ./download-gguf.sh`로 받고 `.env`에 `LLAMA_MMPROJ` 경로를 지정한다.
- `--jinja` 플래그로 chat template·tool calling이 처리되므로 코딩 에이전트(Codex/OpenCode) 연결이 가능하다. Codex 연결은 루트 README의 "환경 변수로 설정 바꾸기" 방법 B 참고:

```bash
CODEX_MODEL=qwen3.6-35b-uncensored CODEX_BASE_URL=http://127.0.0.1:8080/v1 ../install-codex-config.sh
```

## OOM이면

1. `GGUF_QUANT=Q5_K_P ./download-gguf.sh` 후 `MODEL_PATH` 교체 (~28 GB)
2. `LLAMA_CTX_SIZE=65536`
3. 화면 출력에 GPU 0을 쓰면 `LLAMA_TENSOR_SPLIT=0.45,0.55`

## 운영 참고

- `LLAMA_PARALLEL`은 기본 1이다. llama.cpp는 컨텍스트를 슬롯 수로 나누므로(`131072 / 2 = 슬롯당 65536`), 코딩 에이전트의 백그라운드 병렬 요청까지 받으려면 `LLAMA_PARALLEL=2`로 올리되 슬롯당 컨텍스트가 절반이 되는 것을 감안한다.
- 외부 접근이 필요할 때만 `HOST=0.0.0.0`으로 바꾸고 방화벽 또는 리버스 프록시 인증을 함께 설정한다.
- 이 디렉터리의 `.env`, 모델, llama.cpp checkout, PID 파일은 Git에서 제외된다.
