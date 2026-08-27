# llmfit 비교와 하드웨어 어드바이저 설계

조사 기준: 2026-08-27, [`AlexsJones/llmfit`](https://github.com/AlexsJones/llmfit)
`main` 커밋 `99d01a8`, 태그 `v1.1.11`. upstream은 MIT 라이선스다.

## 결론

두 레포는 겹쳐 보이지만 책임이 다르다.

- **llmfit**은 수백 개 모델 중 이 하드웨어에서 실행할 모델과 양자화를 찾는 범용
  탐색기다.
- **vllm-setting**은 이미 선택한 소수 모델을 특정 GPU 구성에서 어떤 vLLM 또는
  llama.cpp 플래그로 안정적으로 띄울지 관리하는 실행 레시피다.

따라서 llmfit의 모델 데이터베이스나 점수 공식을 복제하지 않았다. 대신
`recommend-settings.sh`를 추가해 이 레포에 실제로 있는 실행 타깃을 자동 감지한
하드웨어와 대조하고, 맞는 실행 파일과 설정을 추천하게 했다.

## 기능 비교

| 기능 | llmfit | vllm-setting |
|---|---|---|
| 주 목적 | 광범위한 모델 탐색·적합도 순위 | 검증된 서빙 레시피 실행·운영 |
| 모델 범위 | 내장 Hugging Face 모델 DB 수백 종 | Qwen 중심 추적 타깃 4종 |
| 하드웨어 감지 | NVIDIA, AMD, Intel, Apple, Ascend, CPU | NVIDIA CUDA + Linux RAM/CPU/shm/disk |
| 메모리 판정 | 모델 가중치·KV·양자화 추정 | 각 실행 스크립트의 실제 사전 점검 임계값 |
| 양자화 | 가장 높은 품질의 실행 가능 양자화 동적 선택 | 타깃에 고정된 BF16/FP8/GGUF/AWQ |
| 점수 | 품질·속도·fit·context 복합 점수 | 실행 적합도 밴드 + 타깃 우선순위 |
| 실행 경로 | GPU, MoE offload, CPU+GPU, CPU | vLLM TP 또는 llama.cpp GPU layer split |
| 하드웨어 가상화 | VRAM/RAM/CPU 오버라이드 | GPU 수/name/VRAM/free VRAM/CC/RAM/CPU 오버라이드 |
| 계획 출력 | 모델별 필요 하드웨어와 upgrade delta | 타깃별 요구량·현재 차이·실행 설정과 runner |
| 자동화 출력 | JSON, REST, MCP | JSON CLI |
| 다운로드·프로바이더 | Ollama, llama.cpp, MLX, Docker, LM Studio | Hugging Face 자동 다운로드 + 별도 GGUF 스크립트 |
| 실측 보정 | 로컬·커뮤니티 benchmark로 tok/s 보정 | `benchmark-smoke.sh` 수동 실측 |
| UI | TUI, 웹/데스크톱 | 텍스트 CLI |

llmfit의 계산 방식과 기능은 upstream의
[`docs/how-it-works.md`](https://github.com/AlexsJones/llmfit/blob/main/docs/how-it-works.md),
[`docs/cli.md`](https://github.com/AlexsJones/llmfit/blob/main/docs/cli.md),
[`docs/providers.md`](https://github.com/AlexsJones/llmfit/blob/main/docs/providers.md)를
기준으로 확인했다.

## 가져온 설계 개념

### 1. 하드웨어 자동 감지

`nvidia-smi`에서 GPU별 이름, 전체 VRAM, 현재 여유 VRAM, compute capability를
읽는다. 시스템 RAM은 `/proc/meminfo`, CPU는 `nproc`, NCCL 공유 메모리는
`/dev/shm`, 모델 다운로드 여유는 홈 파일시스템에서 읽는다.

멀티 GPU는 합계 VRAM만 보지 않는다. 현재 타깃이 TP=2이고 각 rank가 한 GPU에
올라가므로 **가장 작은 GPU의 전체/여유 VRAM과 가장 낮은 compute capability**를
기준으로 판정한다. 서로 다른 GPU를 섞었을 때 합계만 보고 잘못 통과시키는 것을
막는다.

### 2. 네 단계 적합도

llmfit의 `Perfect`, `Good`, `Marginal`, `Too Tight` 개념을 이 레포의 실행 레시피에
맞게 적용했다.

| 판정 | 의미 |
|---|---|
| `perfect` | 타깃이 의도한 GPU family이며 전체 용량과 현재 여유 용량이 모두 맞음 |
| `good` | GPU 이름은 다르지만 GPU 수·VRAM·compute capability가 실행 조건을 만족 |
| `marginal` | 전체 용량은 맞지만 현재 다른 프로세스가 VRAM을 쓰거나 CC를 확인할 수 없음 |
| `too_tight` | GPU 수, 전체 VRAM 또는 compute capability 하드 조건을 만족하지 못함 |

`fit`과 `ready`를 분리한 점은 이 레포에 필요한 추가 구분이다. 예를 들어 2x4090이
장착돼도 다른 작업이 VRAM을 쓰는 중이면 하드웨어 소유 용량은 맞지만 지금 바로
서버를 띄울 수는 없다. 이때 `fit=marginal`, `ready=false`가 된다.

### 3. 하드웨어 시뮬레이션

실제 GPU 서버에 접속하지 않고 배포 계획을 검증할 수 있다.

```bash
./recommend-settings.sh \
  --gpu-count 2 \
  --gpu-name 'NVIDIA GeForce RTX 4090' \
  --vram-mib 24564 \
  --free-vram-mib 24564 \
  --compute-cap 8.9 \
  --ram-gib 128 \
  --cpu-cores 32
```

오버라이드는 감지값을 부분적으로 교체할 수 있다. GPU 관련 값이 하나라도 주어지면
동일 GPU로 구성된 시뮬레이션으로 표시한다.

### 4. 계획과 JSON

`plan`은 선택한 타깃의 현재 판정, 최소 조건, 권장 컨텍스트/KV/동시성, 설정 파일과
실행 명령을 한 번에 보여 준다.

```bash
./recommend-settings.sh plan qwen38-27b-4090x2
./recommend-settings.sh plan qwen38-27b-4090x2 --json | jq .
```

`recommend --json`은 `system`, `recommendation`, 정렬된 `targets`를 안정된 키로
반환한다. 다른 설치 스크립트나 관리 UI가 텍스트 표를 파싱할 필요가 없다.

## 일부러 가져오지 않은 기능

### 범용 모델 DB와 품질 점수

vllm-setting이 모델 탐색기까지 소유하면 모델 metadata, 라이선스, 양자화 artifact,
benchmark를 계속 갱신해야 한다. 이 일은 llmfit이 더 넓게 수행한다. 이 레포에서
지원하지 않는 GPU에 맞는 모델을 찾을 때는 llmfit을 그대로 사용한다.

```bash
llmfit recommend --use-case coding --json
```

그 결과를 바로 “지원 타깃”이라고 부르지는 않는다. 실제 launch script를 추가하고
`health-check.sh`, `benchmark-smoke.sh`, OOM/장문 컨텍스트 검증을 통과한 뒤 이
레포의 advisor catalog에 넣는다.

### 추정 tok/s

메모리 대역폭만으로 vLLM의 TP 통신, prefix caching, chunked prefill, 동시 요청,
hybrid attention 성능을 충분히 설명할 수 없다. 이 레포는 추정 tok/s를 표시하지
않고 실제 서버에 `benchmark-smoke.sh`를 실행하는 것을 최종 근거로 둔다.

### TUI, REST, MCP, 모델 다운로드 UI

현재 타깃이 4개뿐이라 TUI나 상주 API는 운영 복잡도만 늘린다. JSON CLI가 자동화
계약을 충족한다. 타깃 수나 여러 노드 스케줄링 요구가 생길 때 다시 평가한다.

## 정확도 경계

advisor는 **실행 전 정적 판정기**다. 아래를 보장하지 않는다.

- CUDA allocator fragmentation이나 실행 순간의 VRAM 변동
- 드라이버, CUDA, PyTorch, vLLM 버전 조합의 실제 호환성
- 모델 저장소가 바뀌었을 때의 가중치 크기
- 실제 tok/s, TTFT, tool-call 정확도, 장문 품질
- NVLink/PCIe topology에 따른 통신 병목

최종 판정 순서는 다음과 같다.

1. `recommend-settings.sh`로 타깃을 고른다.
2. 해당 runner의 사전 점검을 통과한다.
3. `health-check.sh`로 OpenAI 호환 응답을 확인한다.
4. `benchmark-smoke.sh`로 현재 설정의 실제 성능을 잰다.
5. OOM이면 타깃 문서의 순서대로 context/KV/동시성을 조정한다.

## 유지보수 규칙

실행 스크립트의 모델이나 기본값을 바꾸면 같은 커밋에서 다음을 함께 바꾼다.

1. `recommend-settings.sh`의 target catalog
2. 해당 `*.env.example`
3. `docs/targets.md`와 `docs/config.md`
4. `tests/recommend-settings-test.sh`의 예상 추천/설정

advisor가 launch script를 호출하거나 설정 파일을 자동 수정하지 않는 것은 의도된
경계다. 추천을 확인한 뒤 사용자가 실행하며, 기존 로컬 `.env`를 덮어쓰지 않는다.

## 라이선스와 구현 출처

llmfit은 MIT 라이선스이며, 이 기능은 공개된 동작과 설계 개념을 비교한 뒤 이
레포의 기존 셸 패턴과 타깃 임계값으로 독립 구현했다. upstream 소스 파일이나 모델
데이터를 복사하지 않았다. 향후 코드를 직접 가져오면 원 저작권 고지와 MIT
라이선스를 함께 포함해야 한다.
