# vllm-setting

로컬 GPU에서 Qwen 계열 LLM을 OpenAI 호환 API로 서빙하고, Codex CLI·Claude Code 같은 코딩 에이전트를 연결하기 위한 셸 스크립트 + 환경 프로필 모음입니다.

## 서빙 타깃

하드웨어 구성 하나가 `targets/` 아래 실행 스크립트 하나에 대응합니다. 설정값과 실행법은 **[docs/targets.md](docs/targets.md)** 에 타깃별로 정리돼 있습니다.

| 타깃 | 하드웨어 | 모델 | 서빙 이름 |
|---|---|---|---|
| `targets/qwen36-27b-4090x2.sh` | 2x RTX 4090 | `Qwen/Qwen3.6-27B-FP8` | `qwen3.6-27b-fp8` |
| `targets/qwen38-27b-h100x2.sh` | 2x H100 80GB | `Qwen/Qwen3.8-27B` (BF16) | `qwen3.8-27b` |
| `targets/qwen38-27b-4090x2.sh` | 2x RTX 4090 | `Qwen/Qwen3.8-27B-FP8` | `qwen3.8-27b-fp8` |
| `qwen3-coder-2080ti/` | 2x RTX 2080 Ti | `Qwen3-Coder-30B-A3B-Instruct` GGUF | `qwen3-coder-30b-a3b` |

vLLM 타깃 셋은 모두 `http://localhost:8000/v1`, 2080 Ti 구성만 llama.cpp에 `http://127.0.0.1:8080/v1` 입니다.

## 내 하드웨어에 맞는 설정 찾기

먼저 advisor를 실행하면 GPU별 VRAM·여유 VRAM·compute capability와 RAM/CPU를
감지해 이 레포의 타깃을 `perfect/good/marginal/too_tight`로 평가합니다.

```bash
./recommend-settings.sh                          # 타깃 전체 순위
./recommend-settings.sh system --json | jq .     # 하드웨어 JSON
./recommend-settings.sh plan qwen38-27b-4090x2   # 한 타깃의 설정·실행 계획
```

다른 서버를 미리 검토할 때는 GPU 수·이름·VRAM·compute capability를 오버라이드할
수 있습니다. advisor는 설정 파일을 덮어쓰거나 서버를 실행하지 않습니다. 범용 모델
탐색기 `llmfit`과의 역할 차이와 채택한 기능은
**[docs/llmfit-comparison.md](docs/llmfit-comparison.md)** 에 정리했습니다.

## 빠른 시작

기본 구성(2x RTX 4090 + Qwen3.6-27B-FP8) 기준입니다. 다른 하드웨어라면 [docs/targets.md](docs/targets.md)에서 해당 타깃 절을 보세요.

```bash
uv venv && source .venv/bin/activate
uv pip install -U vllm --torch-backend=auto

cp .env.example .env
chmod +x *.sh targets/*.sh

./targets/qwen36-27b-4090x2.sh   # 시작 → http://localhost:8000/v1
./health-check.sh                # /v1/models 대기 후 chat completion 확인
./stop-vllm.sh                   # 종료
```

OpenAI SDK 호환 클라이언트 연결:

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:8000/v1", api_key="EMPTY")
response = client.chat.completions.create(
    model="qwen3.6-27b-fp8",
    messages=[{"role": "user", "content": "Write a concise Python binary search function."}],
    temperature=0.6,
    top_p=0.95,
    max_tokens=2048,
)
print(response.choices[0].message.content)
```

## 문서

| 문서 | 내용 |
|---|---|
| [docs/targets.md](docs/targets.md) | **타깃별 가이드** — 하드웨어별 설정값·실행·종료·OOM 대처. 보통 여기만 보면 됩니다 |
| [docs/scripts.md](docs/scripts.md) | 보조 스크립트 — 종료·헬스체크·벤치마크·프로필 전환·systemd·installer |
| [docs/config.md](docs/config.md) | 설정 항목 전체 레퍼런스와 컨텍스트 튜닝 노트 |
| [docs/agents.md](docs/agents.md) | Codex CLI · OpenCode · Claude Code 연동 |
| [docs/design.md](docs/design.md) | 설계 원칙과 실행·데이터 흐름 |
| [docs/llmfit-comparison.md](docs/llmfit-comparison.md) | llmfit 비교, advisor 판정 기준·한계·유지보수 규칙 |

## 코드 구성

```text
vllm-setting/
├── targets/                       # 하드웨어 구성별 실행 스크립트
│   ├── qwen36-27b-4090x2.sh       #   2x 4090, Qwen3.6-27B-FP8 (공유 .env 사용)
│   ├── qwen38-27b-h100x2.sh       #   2x H100 80GB, Qwen3.8-27B BF16
│   ├── qwen38-27b-4090x2.sh       #   2x 4090, Qwen3.8-27B-FP8
│   ├── qwen38-27b-h100x2.env.example
│   └── qwen38-27b-4090x2.env.example
├── stop-vllm.sh                   # vLLM 프로세스 트리 종료 및 GPU 반환
├── recommend-settings.sh          # 하드웨어 감지, 타깃 적합도·실행 설정 추천(JSON 지원)
├── health-check.sh                # /v1/models + chat completion 확인
├── benchmark-smoke.sh             # 코딩 프롬프트 3종 성능 스모크 테스트
├── use-profile.sh                 # profiles/*.env를 .env로 활성화(백업 포함)
├── install-systemd-user.sh        # systemd --user 서비스 설치
├── install-codex-config.sh        # Codex 프로필 파일 생성
├── install-opencode-config.sh     # OpenCode에 로컬 서버 프로바이더 등록
├── .env.example                   # 공유 설정 예시 (qwen36 타깃 + 보조 스크립트용)
├── profiles/
│   ├── 64k.env                    # 안정 기본 프로필 (MAX_MODEL_LEN=65536)
│   └── 128k.env                   # 롱 컨텍스트 프로필 (MAX_MODEL_LEN=131072)
├── systemd/
│   └── vllm-qwen36.service.in     # systemd user 서비스 템플릿
├── docs/                          # 상세 문서
├── tests/
│   └── recommend-settings-test.sh # advisor 시뮬레이션·JSON 회귀 테스트
└── qwen3-coder-2080ti/            # 2x RTX 2080 Ti용 별도 구성 (llama.cpp 권장)
```

`.env`, `targets/*.env`, `*.pid`, 모델 파일, llama.cpp 체크아웃은 `.gitignore`로 Git에서 제외됩니다.

## 설정 파일이 두 갈래인 이유

`targets/qwen36-27b-4090x2.sh`만 레포 루트의 공유 `.env`를 읽습니다. `use-profile.sh`와 두 installer가 같은 파일을 보기 때문입니다.

Qwen3.8 타깃 두 개는 **각자의 `targets/*.env`를 읽습니다.** 공유 `.env`의 `MODEL`이 Qwen3.6을 가리키고 있어서, 같이 읽으면 모델이 조용히 덮어써집니다. 설정 파일이 없어도 스크립트 내장 기본값으로 동작합니다.
