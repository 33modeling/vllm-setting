# 코딩 에이전트 연동


Codex·OpenCode·Claude Code 공통 전제는 하나입니다: **서버가 떠 있어야 합니다.** 에이전트에 필요한 tool calling은 기본으로 켜져 있습니다(아래 참고).

## 참고: tool calling은 기본으로 켜져 있음

코딩 에이전트는 파일 편집·명령 실행을 전부 **tool calling**(모델이 작업 지시를 일반 텍스트가 아닌 구조화된 함수 호출로 응답하는 기능)으로 수행합니다. 이 레포는 기본값으로 이 기능이 켜져 있어서 — 타깃 스크립트가 `vllm serve`에 `--enable-auto-tool-choice --tool-call-parser qwen3_coder` 옵션을 자동으로 붙입니다 — 별도 설정 없이 서버만 띄우면 됩니다.

- 이 스위치(`ENABLE_TOOL_CALLS`)는 vLLM **서버** 쪽 설정입니다. Codex/Claude Code 클라이언트 설정(`~/.codex/config.toml` 등)과는 무관합니다.
- tool을 쓰지 않는 일반 채팅 요청에는 영향이 없으므로 켜둬도 무방합니다. 끄고 싶을 때만 `.env`에 `ENABLE_TOOL_CALLS=0`을 넣고 서버를 재시작합니다.

## Codex CLI

로컬 서버를 Codex에 **선택 옵션으로 등록**하는 방식입니다. Codex의 기본 모델(OpenAI)은 그대로 유지되고, 쓰고 싶을 때만 로컬 모델로 전환합니다.

```bash
./targets/qwen36-27b-4090x2.sh       # 1) 서버 시작 (또는 systemctl --user start vllm-qwen36)
./install-codex-config.sh     # 2) 최초 1회: 로컬 서버를 프로필로 등록 (기본 모델은 안 바뀜)
codex                         # 3a) 원래 기본 모델로 실행 (평소처럼)
codex --profile qwen-local    # 3b) 로컬 qwen3.6-27b-fp8로 실행
```

모델 전환 방법:

- **실행할 때 선택**: `codex --profile qwen-local` (로컬) / 그냥 `codex` (원래 모델). 이게 유일하게 확실한 전환 방법입니다.
- **세션 중 전환은 안 됩니다** (Codex 0.132 기준 확인): `/model` 목록에 커스텀 프로바이더 모델이 나오지 않으므로, 모델을 바꾸려면 세션을 종료하고 `--profile` 유무를 바꿔 다시 시작하세요.
- **프로필 없이 1회성 지정**: `codex -m qwen3.6-27b-fp8 -c model_provider=vllm`

## 승인 생략 모드(`--yolo`)로 실행

`--yolo`(= `--dangerously-bypass-approvals-and-sandbox`)는 파일 수정·명령 실행 때마다 뜨는 승인 프롬프트를 생략하고 샌드박스도 해제합니다. 프로필 플래그와 나란히 붙이면 됩니다:

```bash
codex --profile qwen-local --yolo
```

매번 치기 귀찮으면 셸 alias로 등록하세요 (`~/.bashrc`에 추가):

```bash
alias qcodex='codex --profile qwen-local --yolo'
```

> ⚠️ 모델이 묻지 않고 바로 파일을 고치고 명령을 실행하게 되므로, **신뢰하는 작업 폴더에서만** 쓰세요. 참고: 프로필 파일에 `approval_policy = "never"` / `sandbox_mode = "danger-full-access"`를 넣어 같은 효과를 낼 수도 있지만, `qwen-local.config.toml`은 `install-codex-config.sh`가 통째로 관리해서 재실행 시 덮어써지므로 alias 방식을 권장합니다.

## 환경 변수로 설정 바꾸기

`install-codex-config.sh`는 **실행하는 시점에** 아래 변수를 읽어 프로필 파일을 만듭니다. 즉, 변수를 바꾼 뒤에는 **스크립트를 다시 실행해야** 반영됩니다.

| 변수 | 기본값 | 의미 |
|---|---|---|
| `CODEX_MODEL` | `.env`의 `SERVED_MODEL_NAME` (기본 `qwen3.6-27b-fp8`) | config에 기록할 모델명. 서버의 서빙 이름과 일치해야 함 |
| `CODEX_BASE_URL` | `http://127.0.0.1:$PORT/v1` (기본 포트 8000) | Codex가 접속할 서버 주소 |
| `CODEX_PROFILE` | `qwen-local` | 프로필 이름이자 파일명(`<이름>.config.toml`) — `codex --profile <이 이름>`으로 로컬 모델 선택 |
| `CODEX_HOME` | `~/.codex` | 프로필 파일을 쓸 디렉터리 |

바꾸는 방법은 두 가지입니다.

**방법 A — `.env`에 영구 저장 (반복 사용 시 권장).** 레포 루트의 `.env` 파일에 값을 추가하면 스크립트가 실행할 때마다 자동으로 읽습니다. `.env.example` 하단에 주석 처리된 예시가 있으니 주석을 풀어 쓰면 됩니다.

```bash
# .env 파일에 추가 (편집: nano .env 또는 vi .env)
CODEX_MODEL=qwen3.6-27b-fp8
CODEX_BASE_URL=http://127.0.0.1:8000/v1
```

```bash
./install-codex-config.sh   # 수정 후 재실행해야 config.toml에 반영됨
```

**방법 B — 명령 앞에 1회성으로 지정 (임시 전환 시).** 터미널에서 명령 앞에 `변수=값`을 붙이면 그 실행에만 적용되고 `.env`는 건드리지 않습니다.

```bash
# 예: 2080 Ti 구성의 llama.cpp 서버(포트 8080)로 임시 전환
CODEX_MODEL=qwen3-coder-30b-a3b CODEX_BASE_URL=http://127.0.0.1:8080/v1 ./install-codex-config.sh
```

생성 결과는 프로필 파일 **`~/.codex/qwen-local.config.toml`**입니다. 최신 Codex는 프로필을 `config.toml` 안이 아니라 프로필별 별도 파일로 요구하며, `codex --profile qwen-local`로 실행하면 이 파일이 `config.toml` 위에 오버레이됩니다. 파일 전체를 스크립트가 관리하므로 직접 수정한 내용은 재실행 시 덮어써집니다(타임스탬프 백업은 남음):

```toml
# Managed by vllm-setting/install-codex-config.sh — rerun it to regenerate.
model = "qwen3.6-27b-fp8"
model_provider = "vllm"

[model_providers.vllm]
name = "vLLM local (qwen3.6-27b-fp8)"
base_url = "http://127.0.0.1:8000/v1"
wire_api = "responses"
```

`config.toml`은 건드리지 않으므로 Codex의 기본 모델은 그대로입니다. 구버전 스크립트가 config.toml 안에 넣어둔 프로필 블록 때문에 Codex가 "config.toml 안의 프로필은 지원되지 않는다"는 에러를 낸다면, 이 스크립트를 다시 실행하세요 — 백업 후 해당 블록을 제거하고 별도 파일로 옮겨줍니다.

> ⚠️ **`wire_api`는 `"responses"`여야 합니다.** Codex 0.132부터 `wire_api = "chat"`(Chat Completions 방식)이 제거돼 config에 남아 있으면 `wire_api = "chat" is no longer supported` 에러가 납니다. 예전 버전 스크립트로 등록했다면 `./install-codex-config.sh`를 다시 실행하면 갱신됩니다. 대신 서버 쪽 vLLM이 Responses API(`/v1/responses`)를 지원해야 하므로, 요청이 404로 실패하면 vLLM을 최신으로 업그레이드하세요(`uv pip install -U vllm`).

## OpenCode

OpenCode는 커스텀 프로바이더를 1급으로 지원해서 연동이 가장 단순합니다 — OpenAI 호환(Chat Completions)으로 바로 붙으므로 Codex처럼 vLLM의 Responses API 지원 여부를 신경 쓸 필요가 없습니다.

```bash
./install-opencode-config.sh              # 최초 1회 또는 서빙 이름·주소 변경 시: 프로바이더 등록
opencode                                  # 기본 모델 그대로 실행 → /models로 로컬 모델 선택
opencode -m vllm/qwen3.6-27b-fp8          # 로컬 모델로 바로 실행
```

- 등록은 전역 설정 `~/.config/opencode/opencode.json`의 `provider.vllm` 항목 하나만 갱신하며, 기본 모델·테마 등 나머지 설정은 보존됩니다.
- **세션 중 모델 전환은 `/models`로 자유롭게 가능합니다** (Codex와 달리 재시작 불필요).
- 이미 OpenCode에 직접 등록해뒀다면: 이 스크립트는 `provider.vllm` 키를 사용하므로, 직접 만든 항목이 다른 키 이름이면 중복 등록될 수 있습니다. `OPENCODE_PROVIDER=<기존 키>`로 맞춰 실행하면 기존 항목을 갱신합니다. **서빙 이름이 `qwen3.6-27b-fp8`로 바뀌었으므로, 옛 이름(`qwen3.6-27b`)으로 등록된 기존 설정은 이 스크립트를 한 번 실행해 갱신하세요.**

환경 변수 (모두 실행 시점에 읽음 — 바꾼 뒤 재실행 필요):

| 변수 | 기본값 | 의미 |
|---|---|---|
| `OPENCODE_MODEL` | `.env`의 `SERVED_MODEL_NAME` | 등록할 모델명 (서빙 이름과 일치해야 함) |
| `OPENCODE_BASE_URL` | `http://127.0.0.1:$PORT/v1` | OpenCode가 접속할 서버 주소 |
| `OPENCODE_PROVIDER` | `vllm` | opencode.json의 프로바이더 키 이름 |
| `OPENCODE_CONFIG` | `~/.config/opencode/opencode.json` | 설정 파일 경로 |

## Claude Code

Claude Code는 Anthropic Messages API(`/v1/messages`) 형식으로 통신하므로, OpenAI 호환 엔드포인트인 이 서버에 바로 붙일 수 없고 LiteLLM 프록시를 변환 계층으로 둡니다.

**1) LiteLLM 설치 및 실행:**

```bash
pip install 'litellm[proxy]'
```

```yaml
# litellm_config.yaml
model_list:
  - model_name: qwen3.6-27b-fp8
    litellm_params:
      model: hosted_vllm/qwen3.6-27b-fp8
      api_base: http://localhost:8000/v1
```

```bash
litellm --config litellm_config.yaml --port 4000
```

**2) Claude Code가 프록시를 보도록 환경 변수 설정.** 두 방법 중 하나를 씁니다.

방법 A — `~/.claude/settings.json`의 `"env"` 블록에 저장 (권장, Claude Code 실행 시 항상 적용):

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://localhost:4000",
    "ANTHROPIC_AUTH_TOKEN": "dummy",
    "ANTHROPIC_MODEL": "qwen3.6-27b-fp8",
    "ANTHROPIC_SMALL_FAST_MODEL": "qwen3.6-27b-fp8"
  }
}
```

방법 B — 터미널에서 export 후 실행 (그 터미널 세션에만 적용):

```bash
export ANTHROPIC_BASE_URL="http://localhost:4000"
export ANTHROPIC_AUTH_TOKEN="dummy"
export ANTHROPIC_MODEL="qwen3.6-27b-fp8"
export ANTHROPIC_SMALL_FAST_MODEL="qwen3.6-27b-fp8"
claude
```

**참고 — 프록시 없이 직결:** 최근 vLLM은 Anthropic 호환 `/v1/messages` 엔드포인트를 자체 지원하기 시작했습니다. 서버 실행 후 `curl -s localhost:8000/v1/messages`가 404가 아니면, LiteLLM 없이 `ANTHROPIC_BASE_URL=http://localhost:8000`으로 직결할 수 있습니다.

## 공통 주의사항

- **tool calling이 꺼져 있으면 동작 불가.** 기본은 켜져 있으므로 보통 신경 쓸 일이 없지만, `.env`에 `ENABLE_TOOL_CALLS=0`을 넣었다면 에이전트가 파일 수정·명령 실행을 전혀 못 합니다.
- **병렬 요청은 `MAX_NUM_SEQS`가 처리.** Claude Code는 본 요청 외에 백그라운드 요청(세션 제목 생성, 서브에이전트 등)을 병렬로 보내는데, 기본값이 `2`라 별도 설정 없이 대응됩니다. 서브에이전트를 많이 쓴다면 `3`~`4`로 올리세요. prefix caching이 켜져 있어 KV cache 부담은 크지 않습니다.
- **컨텍스트는 넉넉하게.** 에이전트의 시스템 프롬프트 + 도구 정의만으로 수만 토큰을 차지하므로 64K 이상(가능하면 `./use-profile.sh 128k`)을 권장합니다.
- 웹 검색 같은 Anthropic 서버사이드 기능은 커스텀 백엔드에서 동작하지 않습니다.
