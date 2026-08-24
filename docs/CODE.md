# 코드 구조

파일별 내부 로직, 실제 상수와 임계값, 설정 스키마 전체, 진입점부터의 호출 흐름, 외부 의존을 다룬다. "어느 값을 왜 그렇게 잡았나"는 [config.md](config.md)·[targets.md](targets.md), "어떻게 쓰나"는 [USAGE.md](USAGE.md), "왜 이렇게 나눴나"는 [ARCHITECTURE.md](ARCHITECTURE.md)에 있다. 이 문서는 **코드에 실제로 적힌 것**만 담는다.

## 1. 파일 인벤토리

`git ls-files -s` + `wc -l` 실측. 추적 파일 31개, 2,633줄.

### 1.1 루트

| 파일 | 줄 | git mode | env 파일 로드 | 역할 |
|---|---:|---|---|---|
| `stop-vllm.sh` | 109 | 100755 | 루트 `.env` | 프로세스 트리 종료 |
| `benchmark-smoke.sh` | 116 | 100755 | 루트 `.env` | 코딩 프롬프트 3종 벤치마크 |
| `install-codex-config.sh` | 113 | 100755 | 루트 `.env` | Codex 프로필 파일 생성 + 구버전 마이그레이션 |
| `install-opencode-config.sh` | 86 | 100755 | 루트 `.env` | opencode.json에 프로바이더 병합 |
| `health-check.sh` | 84 | 100755 | 루트 `.env` | `/v1/models` 폴링 + chat completion |
| `install-systemd-user.sh` | 48 | 100755 | **없음** | systemd user 유닛 설치 |
| `use-profile.sh` | 41 | 100755 | **없음** (읽지 않고 덮어씀) | `profiles/*.env` → `.env` |
| `README.md` | 93 | 100644 | — | 개요 |
| `.env.example` | 40 | 100644 | — | 루트 공유 설정 템플릿 |
| `.gitignore` | 14 | 100644 | — | 14개 규칙 |

### 1.2 `targets/`

| 파일 | 줄 | git mode | 읽는 설정 파일 | PID 파일 기본값 |
|---|---:|---|---|---|
| `qwen38-27b-4090x2.sh` | 236 | 100755 | `targets/qwen38-27b-4090x2.env` | `<repo>/vllm-qwen38-4090x2.pid` |
| `qwen38-27b-h100x2.sh` | 229 | 100755 | `targets/qwen38-27b-h100x2.env` | `<repo>/vllm-qwen38-h100x2.pid` |
| `qwen36-27b-4090x2.sh` | 187 | 100755 | 루트 `.env` | `<repo>/vllm.pid` |
| `qwen38-27b-h100x2.env.example` | 45 | 100644 | — | — |
| `qwen38-27b-4090x2.env.example` | 42 | 100644 | — | — |

### 1.3 `profiles/`, `systemd/`

| 파일 | 줄 | 내용 |
|---|---:|---|
| `profiles/128k.env` | 28 | `MAX_MODEL_LEN=131072`, `TIMEOUT_SECONDS=45`, `WAIT_READY_SECONDS=420`, `REQUEST_TIMEOUT=180` |
| `profiles/64k.env` | 25 | `.env.example`과 **값 집합이 동일** (주석과 `#CODEX_*` 예시만 없음) |
| `systemd/vllm-qwen36.service.in` | 18 | `__WORKDIR__` 치환 템플릿, 유닛 1개 |

`64k.env`와 `128k.env`의 차이는 위 4개 값뿐이고 나머지 16개 항목은 동일하다.

### 1.4 `qwen3-coder-2080ti/`

| 파일 | 줄 | git mode | 역할 |
|---|---:|---|---|
| `run-vllm-server.sh` | 123 | 100755 | AWQ 4-bit vLLM (대안 경로) |
| `run-llama-server.sh` | 102 | 100755 | GGUF llama-server (권장 경로) |
| `health-check.sh` | 56 | 100755 | `BACKEND`로 8080/8000 선택 |
| `stop-server.sh` | 46 | 100755 | PID 파일 2개 순회 종료 |
| `install-llama-cpp.sh` | 44 | 100755 | llama.cpp clone + CUDA 빌드 |
| `download-gguf.sh` | 29 | 100755 | GGUF 이어받기 다운로드 |
| `README.md` | 73 | 100644 | 이 하위 트리 전용 안내 |
| `.env.example` | 23 | 100644 | 이 하위 트리 전용 설정 템플릿 |

## 2. 모든 스크립트가 공유하는 프렐류드

16개 스크립트 전부가 아래 세 가지를 동일하게 갖는다(실측: `grep -c` 결과 16/16).

### 2.1 셔뱅과 셸 옵션

```bash
#!/usr/bin/env bash
set -euo pipefail
```

`set -e` 때문에 명령 하나가 실패하면 즉시 종료된다. 이 성질이 `benchmark-smoke.sh`에서 눈에 보이는 결과를 만든다(§4.3).

### 2.2 위치 해석

16개 파일 전부 **글자 하나까지 같은 한 줄**을 쓴다.

```bash
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
```

`targets/*.sh`만 여기에 한 줄을 더한다.

```bash
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
```

| 변수 | 값 | 쓰는 곳 |
|---|---|---|
| `SCRIPT_DIR` (targets) | `<repo>/targets` | `ENV_FILE` 기본 경로 |
| `REPO_ROOT` (targets) | `<repo>` | `PID_FILE` 기본값, `.venv/bin/vllm` 탐색 |
| `SCRIPT_DIR` (루트 스크립트) | `<repo>` | `.env`, `profiles/`, `systemd/` 경로 |
| `SCRIPT_DIR` (2080ti) | `<repo>/qwen3-coder-2080ti` | `.env`, `models/`, `llama.cpp/`, PID 파일 |

호출 위치와 무관하게 동작하므로 `cd`가 필요 없다.

### 2.3 설정 로드와 실제 우선순위

12개 스크립트가 아래 패턴으로 설정 파일을 읽는다(로드하지 않는 4개: `use-profile.sh`, `install-systemd-user.sh`, `qwen3-coder-2080ti/download-gguf.sh`, `qwen3-coder-2080ti/install-llama-cpp.sh`).

```bash
if [[ -f "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE"
  set +a
fi
VAR="${VAR:-내장기본값}"
```

`set -a`는 이후 대입되는 변수를 자동 export한다. **여기서 우선순위가 뒤집힌다.** `source`가 실행하는 `PORT=8000`은 평문 대입이라 환경에서 상속받은 값을 무조건 덮어쓴다. 그 뒤의 `${VAR:-...}`는 "설정 파일에도 없고 환경에도 없는 경우"만 채운다.

**실제 우선순위: 설정 파일 > 명령줄/환경 > 내장 기본값**

최소 재현:

```
$ PORT=9999 bash -c 'set -a; source /home/kms/dev/vllm-setting/.env; set +a; echo "$PORT"'
8000
```

실제 스크립트에서:

```
$ PORT=9999 ./health-check.sh
Checking vLLM at http://127.0.0.1:8000/v1

$ SERVED_MODEL_NAME=qwen3.8-27b ./benchmark-smoke.sh
Benchmark endpoint: http://127.0.0.1:8000/v1
Model: qwen3.6-27b-fp8
```

어떤 변수가 클로버되는지는 §7.5의 표에 정리했다. 요점은 **설정 파일에 그 줄이 있으면 명령줄이 무시된다**는 것이다.

### 2.4 파일 읽기 권한 사전 확인

`targets/*.sh` 3개와 `qwen3-coder-2080ti/run-*.sh` 2개는 `source` 전에 읽기 권한을 확인한다.

```bash
if [[ -f "$ENV_FILE" && ! -r "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE exists but is not readable by user '$(id -un)'." >&2
  echo "       Fix permissions (chmod 644 '$ENV_FILE') or run as the file owner." >&2
  exit 1
fi
```

이 검사가 필요한 이유는 `use-profile.sh`가 `.env`를 **`chmod 600`**으로 만들기 때문이다(§4.4). 소유자와 다른 계정으로 실행하면 여기서 걸린다. 참고로 안내 문구는 `chmod 644`인데 `use-profile.sh`가 만드는 것은 `600`이라, 프로필을 다시 활성화하면 권한이 되돌아간다.

루트 보조 스크립트 4개(`stop-vllm.sh`, `health-check.sh`, `benchmark-smoke.sh`, installer 2종)에는 이 검사가 **없다.** `.env`가 읽기 불가면 `source`에서 `set -e`로 종료된다.

## 3. `targets/*.sh` — 실행층

### 3.1 세 타깃의 상수 비교

스크립트에 하드코딩된 내장 기본값. 설정 파일이 없을 때 실제로 적용되는 값이다.

| 변수 | `qwen36-27b-4090x2` | `qwen38-27b-h100x2` | `qwen38-27b-4090x2` |
|---|---|---|---|
| `MODEL` | `Qwen/Qwen3.6-27B-FP8` | `Qwen/Qwen3.8-27B` | `Qwen/Qwen3.8-27B-FP8` |
| `SERVED_MODEL_NAME` | `qwen3.6-27b-fp8` | `qwen3.8-27b` | `qwen3.8-27b-fp8` |
| `HOST` | `0.0.0.0` | `0.0.0.0` | `0.0.0.0` |
| `PORT` | `8000` | `8000` | `8000` |
| `PID_FILE` | `$REPO_ROOT/vllm.pid` | `$REPO_ROOT/vllm-qwen38-h100x2.pid` | `$REPO_ROOT/vllm-qwen38-4090x2.pid` |
| `CUDA_VISIBLE_DEVICES` | `0,1` | `0,1` | `0,1` |
| `TP_SIZE` | `2` | `2` | `2` |
| `MAX_MODEL_LEN` | `65536` | `262144` | `65536` |
| `GPU_MEMORY_UTILIZATION` | `0.90` | **`0.92`** | `0.90` |
| `MAX_NUM_SEQS` | `2` | **`16`** | `2` |
| `MAX_NUM_BATCHED_TOKENS` | `8192` | **`16384`** | `8192` |
| `DTYPE` | `auto` | `auto` | `auto` |
| `KV_CACHE_DTYPE` | `auto` | **`fp8`** | `auto` |
| `ENABLE_PREFIX_CACHING` | `1` | `1` | `1` |
| `ENABLE_CHUNKED_PREFILL` | `1` | `1` | `1` |
| `DISABLE_CUSTOM_ALL_REDUCE` | `1` | **`0`** | `1` |
| `ENABLE_TOOL_CALLS` | `1` | `1` | `1` |
| `TRUST_REMOTE_CODE` | `0` | `0` | `0` |
| `LANGUAGE_MODEL_ONLY` | **변수 없음** (플래그 무조건 부착) | `0` | `1` |
| `ENABLE_MTP` | 없음 | `0` | 없음 |
| `MTP_NUM_SPECULATIVE_TOKENS` | 없음 | `3` | 없음 |
| `ENV_FILE` | 없음 (`$REPO_ROOT/.env` 고정) | `$SCRIPT_DIR/qwen38-27b-h100x2.env` | `$SCRIPT_DIR/qwen38-27b-4090x2.env` |
| `VLLM_BIN` | 자동 탐색 | 자동 탐색 | 자동 탐색 |

`qwen38-*` 두 타깃만 `ENV_FILE` 환경변수로 설정 파일 경로를 바꿀 수 있다(`ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/...}"`). `qwen36` 타깃은 `$REPO_ROOT/.env` 경로가 하드코딩돼 있어 바꿀 수 없다. **`ENV_FILE`은 기존 문서 어디에도 없다.**

`LANGUAGE_MODEL_ONLY`가 `qwen36` 타깃에 없다는 점이 중요하다. 이 스크립트는 인자 배열에 `--language-model-only`를 조건 없이 넣는다(187줄 중 147줄). 따라서 `LANGUAGE_MODEL_ONLY=0`을 `.env`에 넣어도 **아무 효과가 없고**, 이미지 입력을 쓰려면 스크립트를 고쳐야 한다.

### 3.2 사전 점검 — 단계·임계값·차단 여부

| # | 검사 | qwen36 | q38-h100 | q38-4090 | 실패 시 | 임계값 |
|---:|---|:-:|:-:|:-:|---|---|
| 1 | `vllm` 실행파일 | O | O | O | **exit 1** | `VLLM_BIN` → `PATH` → `$REPO_ROOT/.venv/bin/vllm` |
| 2 | vLLM 버전 | — | O | O | 경고 | `< 0.17.0` |
| 3 | `nvidia-smi` 존재 | O | O | O | **exit 1** | — |
| 4 | GPU 개수 | O | O | O | **exit 1** | `gpu_count < 요청개수` 또는 `< TP_SIZE` |
| 5 | GPU 인덱스 범위 | O | O | O | **exit 1** | 비숫자 또는 `idx >= gpu_count` |
| 6 | compute capability | **—** | — | O | **exit 1** | `< 8.9` |
| 7 | VRAM | O | O | O | **exit 1** | `< 20000` / `< 70000` / `< 20000` MiB |
| 8 | `MODEL` 로컬 경로 존재 | O | O | O | **exit 1** | `/` 또는 `./`로 시작할 때만 |
| 9 | 포트 점유 | O | O | O | **exit 1** | `ss -tln`의 `Local Address:Port`가 `:$PORT`로 끝남 |
| 10 | `/dev/shm` 크기 | O | O | O | 경고 | `< 1048576 KiB` (1 GiB) |
| 11 | 디스크 여유 | O | O | O | 경고 | `< 40` / `< 70` / `< 40` GiB |

비대칭 두 가지가 실측된다.

- **`qwen36` 타깃에 compute capability 검사가 없다.** 서빙 대상인 `Qwen/Qwen3.6-27B-FP8`도 FP8 체크포인트이고 `qwen38-27b-4090x2.sh`는 같은 4090 대상에서 sm89 미만을 차단하는데, `qwen36` 쪽은 그냥 통과시킨다.
- **`qwen36` 타깃에 vLLM 버전 검사가 없다.** Qwen3.8 전용 요구(0.17.0+)라 의도된 차이로 보인다.

세부 로직에서 눈여겨볼 곳.

**VRAM 검사는 `MODEL`이 정확히 기본 문자열일 때만 돈다.**

```bash
if [[ "$MODEL" == "Qwen/Qwen3.6-27B-FP8" ]]; then    # 문자열 완전 일치
```

`MODEL`을 다른 값으로 바꾸면 VRAM 검사가 조용히 건너뛰어진다. `qwen38-27b-h100x2.sh`(`"Qwen/Qwen3.8-27B"`)와 `qwen38-27b-4090x2.sh`(`"Qwen/Qwen3.8-27B-FP8"`)도 같다. 반면 compute capability 검사에는 이 조건이 없어 `MODEL`과 무관하게 항상 돈다.

**버전 비교는 `sort -V`로 한다.**

```bash
vllm_version="$("$VLLM_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
if [[ "$(printf '%s\n0.17.0\n' "$vllm_version" | sort -V | head -1)" != "0.17.0" ]]; then
```

`--version` 출력에서 `x.y.z` 첫 매치만 뽑는다. 매치가 없으면(`nightly`처럼) `$vllm_version`이 빈 문자열이 되고 `if [[ -n ... ]]` 가드에 걸려 검사 자체를 건너뛴다. 정확히 `0.17.0`이면 `head -1`이 `0.17.0`이라 경고하지 않는다.

**compute capability 비교는 awk 부동소수로 한다.**

```bash
min_cc="$(nvidia-smi -i "$CUDA_VISIBLE_DEVICES" --query-gpu=compute_cap --format=csv,noheader | sort -V | head -1)"
if awk -v cc="$min_cc" 'BEGIN { exit !(cc < 8.9) }'; then   # cc < 8.9 이면 exit 0 → 차단
```

`sm${min_cc/./}` 문자열 치환으로 `8.6` → `sm86` 형태의 메시지를 만든다.

**디스크 검사는 HuggingFace 캐시 유무를 먼저 본다.**

```bash
hf_hub_dir="${HF_HOME:-$HOME/.cache/huggingface}/hub/models--${MODEL//\//--}"
```

`${MODEL//\//--}`가 `Qwen/Qwen3.6-27B-FP8` → `Qwen--Qwen3.6-27B-FP8`로 바꾼다. 이 디렉터리가 이미 있으면(= 다운로드 완료) 디스크 검사를 건너뛴다. `HF_HOME`은 **스크립트가 읽기만 하고 설정하지 않는** 유일한 외부 환경변수다.

검증(이 머신에는 vLLM 미설치라 1번에서 멈춘다):

```
$ ./targets/qwen36-27b-4090x2.sh
ERROR: 'vllm' executable not found.
  Searched: PATH, ./.venv/bin/vllm
  vLLM may not be installed on this machine. Install it first (see README):
    uv venv && source .venv/bin/activate && uv pip install -U vllm --torch-backend=auto
  Or point VLLM_BIN at an existing install:
    VLLM_BIN=/path/to/venv/bin/vllm ./targets/qwen36-27b-4090x2.sh
exit=1
```

세 타깃 모두 같은 형태로 실패하며, 마지막 예시 줄만 자기 스크립트 경로로 바뀐다.

`VLLM_BIN`을 실행 가능한 무해한 파일로 지정하면 1단계를 통과시켜 그 다음 단계까지 확인할 수 있다. 이 머신은 GPU가 1장이라 4단계에서 멈춘다.

```
$ VLLM_BIN=/bin/false ./targets/qwen36-27b-4090x2.sh
ERROR: not enough GPUs: found 1, need 2 (CUDA_VISIBLE_DEVICES=0,1, TP_SIZE=2).
       This config targets 2x RTX 4090 — is this the right machine?
exit=1
```

`${#requested_gpus[@]}`(= `CUDA_VISIBLE_DEVICES`를 `,`로 분리한 개수)와 `TP_SIZE`를 각각 `gpu_count`와 비교하며, 메시지에는 앞의 값이 찍힌다.

### 3.3 인자 배열 조립

무조건 들어가는 공통 인자(세 타깃 동일):

```
serve $MODEL
--served-model-name $SERVED_MODEL_NAME
--host $HOST --port $PORT
--tensor-parallel-size $TP_SIZE
--max-model-len $MAX_MODEL_LEN
--gpu-memory-utilization $GPU_MEMORY_UTILIZATION
--max-num-seqs $MAX_NUM_SEQS
--max-num-batched-tokens $MAX_NUM_BATCHED_TOKENS
--dtype $DTYPE
--kv-cache-dtype $KV_CACHE_DTYPE
--reasoning-parser qwen3
```

`qwen36`만 여기에 `--language-model-only`를 무조건 추가한다.

조건부 인자:

| 조건 | 추가되는 인자 | 해당 타깃 |
|---|---|---|
| `LANGUAGE_MODEL_ONLY == 1` | `--language-model-only` | qwen38 2종만 |
| `ENABLE_PREFIX_CACHING == 1` | `--enable-prefix-caching` | 3종 |
| `ENABLE_CHUNKED_PREFILL == 1` | `--enable-chunked-prefill` | 3종 |
| `DISABLE_CUSTOM_ALL_REDUCE == 1` | `--disable-custom-all-reduce` | 3종 |
| `ENABLE_TOOL_CALLS == 1` | `--enable-auto-tool-choice --tool-call-parser qwen3_coder` | 3종 |
| `ENABLE_MTP == 1` | `--speculative-config '{"method":"mtp","num_speculative_tokens":N}'` | h100x2만 |
| `TRUST_REMOTE_CODE == 1` | `--trust-remote-code` | 3종 |

비교는 전부 문자열 `== "1"`이다. `true`, `yes`, `on`은 인식되지 않고 꺼진 것으로 취급된다.

### 3.4 요약 출력과 실행

세 타깃 모두 heredoc으로 실효 설정을 출력한 뒤 종료한다.

```bash
echo "$$" > "$PID_FILE"
exec "$VLLM_BIN" "${args[@]}" "$@"
```

두 가지 결과가 따라온다.

- `"$@"`가 뒤에 붙으므로 **스크립트에 넘긴 인자가 그대로 `vllm serve`에 전달된다.** 예: `./targets/qwen36-27b-4090x2.sh --api-key mykey`. 이 통로는 기존 문서에 없다.
- `exec` 때문에 PID 파일의 값이 곧 vLLM 프로세스의 PID다. 다만 `exec` 직후 vLLM이 죽어도 PID 파일은 남는다(§4.1이 검증으로 걸러낸다).

`qwen38-*` 두 타깃은 요약 마지막에 종료 명령까지 출력한다.

```
  stop with: PID_FILE='<repo>/vllm-qwen38-h100x2.pid' PORT=8000 ./stop-vllm.sh
```

## 4. 루트 보조 스크립트

### 4.1 `stop-vllm.sh` (109줄)

읽는 변수: `PORT`(8000), `PID_FILE`(`$SCRIPT_DIR/vllm.pid`), `MODEL`(`Qwen/Qwen3.6-27B-FP8`), `SERVED_MODEL_NAME`(`qwen3.6-27b-fp8`), `TIMEOUT_SECONDS`(30).

**`add_pid()`** — 4단계 가드로 `pids` 배열에 넣는다: 숫자인가 → 자기 자신(`$$`)이 아닌가 → `kill -0`으로 살아 있는가 → 이미 배열에 있지 않은가.

**`collect_descendants()`** — `pgrep -P <pid>`로 자식을 얻어 재귀 호출한 뒤 자신을 추가한다. 후위 순회라 **깊은 자손이 배열 앞쪽에 온다.**

**탐색 3경로 (순서대로 누적, 배타적이지 않음)**

1. **PID 파일** — `tr -dc '0-9'`로 숫자만 추출(개행·공백 제거) → `kill -0` → `ps -p <pid> -o args=`의 cmdline이 `vllm` 또는 `$MODEL` 또는 `$SERVED_MODEL_NAME`을 포함할 때만 채택. 스테일 PID 재사용으로 무관한 프로세스를 죽이는 것을 막는 검사다.
2. **포트 리스너** — `ss -H -ltnp "sport = :$PORT"` 출력에서 `sed -n 's/.*pid=\([0-9]\+\).*/\1/p'`로 PID를 뽑는다. `ss`가 없으면 건너뛴다.
3. **프로세스 전체 스캔** — `ps -eo pid=,args=`를 돌며 cmdline이 `vllm`과 `serve`를 **모두** 포함하고, 추가로 `$PORT`·`$MODEL`·`$SERVED_MODEL_NAME` 중 **하나라도** 포함하면 채택.

3번 조건에서 `$PORT`는 단순 부분 문자열 매칭이다. 세 vLLM 타깃이 모두 8000을 쓰므로 서로를 잡을 수 있다.

**종료 시퀀스** — 수집된 PID 전부에 `collect_descendants` → `kill -TERM` 일괄 → `SECONDS + TIMEOUT_SECONDS` 데드라인까지 1초 간격 폴링 → 데드라인 후 남은 것만 `kill -KILL` → `rm -f "$PID_FILE"` → `sleep 1`.

대상이 없으면 PID 파일만 지우고 exit 0. 검증:

```
$ ./stop-vllm.sh
No matching vLLM process found.
exit=0

$ PORT=9999 ./stop-vllm.sh
No matching vLLM process found.
exit=0
```

두 번째는 `PORT=9999`가 `.env`의 `PORT=8000`으로 덮어써진 상태의 실행이다.

### 4.2 `health-check.sh` (84줄)

읽는 변수: `HOST`(0.0.0.0), `PORT`(8000), `SERVED_MODEL_NAME`(`qwen3.6-27b-fp8`), `WAIT_READY_SECONDS`(300), `REQUEST_TIMEOUT`(120), `CHAT_CHECK`(1), `BASE_URL`(유도값).

**호스트 치환** — `HOST`가 `0.0.0.0` 또는 `::`이면 접속용 호스트를 `127.0.0.1`로 바꾼다. 그 외에는 `HOST` 그대로.

```bash
BASE_URL="${BASE_URL:-http://$CLIENT_HOST:$PORT/v1}"
```

`BASE_URL`은 `.env.example`에 없으므로 **명령줄 오버라이드가 통하는 몇 안 되는 변수**다.

**임시 파일 3개** — `models_response`, `chat_body`, `chat_response`를 `mktemp`로 만들고 `trap ... EXIT`으로 정리한다.

**폴링 루프** — `curl -fsS --max-time "$REQUEST_TIMEOUT" "$BASE_URL/models"`를 2초 간격으로 재시도. `SECONDS >= deadline`이면 stderr에 실패를 적고 exit 1. `curl`에 `-S`가 있어 **매 시도마다 연결 실패 메시지가 stderr에 찍힌다.** 검증(5초 제한):

```
$ PORT=9999 timeout 5 ./health-check.sh
Checking vLLM at http://127.0.0.1:8000/v1
curl: (7) Failed to connect to 127.0.0.1 port 8000 after 0 ms: Couldn't connect to server
curl: (7) Failed to connect to 127.0.0.1 port 8000 after 0 ms: Couldn't connect to server
curl: (7) Failed to connect to 127.0.0.1 port 8000 after 0 ms: Couldn't connect to server
exit=124   # timeout이 끊음 — 스크립트 자체는 300초까지 계속했을 것
```

**chat 단계** — `CHAT_CHECK != 1`이면 여기서 exit 0. 아니면 아래 본문을 POST한다.

```json
{"model":"$SERVED_MODEL_NAME","messages":[{"role":"user","content":"Reply with exactly: OK"}],"temperature":0,"max_tokens":16}
```

성공하면 `chat completion OK`를 찍고, `jq`가 있으면 `.choices[0].message.content // empty`를 출력한다. **주의**: `max_tokens`가 16이고 타깃 스크립트가 `--reasoning-parser qwen3`을 항상 붙이므로, thinking이 켜진 모델에서는 예산이 reasoning 쪽으로 소진돼 `content`가 빈 문자열일 수 있다. 그래도 HTTP 200이라 스크립트는 `chat completion OK`로 판정한다.

### 4.3 `benchmark-smoke.sh` (116줄)

읽는 변수: `HOST`, `PORT`, `SERVED_MODEL_NAME`, `REQUEST_TIMEOUT`(**내장 기본 180**), `MAX_TOKENS`(← `BENCH_MAX_TOKENS`, 기본 512), `BASE_URL`.

`REQUEST_TIMEOUT` 내장 기본은 180이지만 `.env.example`·`profiles/64k.env`가 `REQUEST_TIMEOUT=120`을 담고 있어 **기본 설정으로는 120이 적용된다.** 180이 실제로 쓰이려면 `.env`가 없거나 `profiles/128k.env`를 활성화해야 한다.

**`extract_number(key, file)`** — `jq` 없이 숫자를 뽑는다.

```bash
grep -o "\"$key\"[[:space:]]*:[[:space:]]*[0-9]*" "$file" | head -n 1 | grep -o '[0-9]*$' || true
```

첫 매치만 쓰므로 `completion_tokens`가 `completion_tokens_details` 같은 하위 객체에도 나타나면 출현 순서에 따라 값이 달라질 수 있다.

**`run_case(name, prompt)`** — `mktemp`로 본문·응답 파일을 만들고, `date +%s%3N`으로 밀리초 시각을 앞뒤로 재고, `temperature=0.2 / top_p=0.95 / max_tokens=$MAX_TOKENS`로 POST한다. tok/s는

```bash
awk "BEGIN { printf \"%.2f\", $completion_tokens / ($elapsed_ms / 1000) }"
```

`completion_tokens`가 비었거나 `0`이면 `n/a`. 출력은 `printf '%-18s elapsed=%6sms completion_tokens=%-5s total_tokens=%-5s tok/s=%s\n'`.

프롬프트는 heredoc으로 JSON에 그대로 삽입되며 이스케이프가 없다. 현재 3개 프롬프트에는 큰따옴표·역슬래시가 없어 문제가 없지만, 프롬프트를 편집할 때는 JSON을 깨뜨리지 않도록 주의해야 한다.

**고정 프롬프트 3종** — `binary-search`, `bug-review`, `lru-cache`.

**`set -e`와의 상호작용** — `run_case`는 실패 시 `return 1`이고 최상위에서 그대로 호출되므로, **첫 케이스가 실패하면 스크립트가 즉시 끝나고 "GPU after" 블록이 실행되지 않는다.** 검증:

```
$ SERVED_MODEL_NAME=qwen3.8-27b ./benchmark-smoke.sh
Benchmark endpoint: http://127.0.0.1:8000/v1
Model: qwen3.6-27b-fp8

GPU before:
0, NVIDIA GeForce RTX 3050, 1286 MiB, 6144 MiB

curl: (7) Failed to connect to 127.0.0.1 port 8000 after 0 ms: Couldn't connect to server
binary-search: failed
exit=1
```

이 한 번의 실행이 세 가지를 동시에 보여준다: 클로버링(`Model:` 줄), `set -e`로 인한 조기 종료(`GPU after` 없음), `print_gpu`의 `nvidia-smi` CSV 포맷.

### 4.4 `use-profile.sh` (41줄)

레포에서 **인자를 받는 유일한 스크립트**다. `.env`를 읽지 않고 쓰기만 한다.

```
$ ./use-profile.sh --help
Usage: ./use-profile.sh <profile>

Available profiles:
  128k
  64k

$ ./use-profile.sh bogus
Unknown profile: bogus
Usage: ./use-profile.sh <profile>
...
exit=1
```

인자 없음 / `-h` / `--help`는 모두 usage 출력 후 **exit 0**, 알 수 없는 프로필은 usage를 stderr로 출력 후 **exit 1**이다.

프로필 목록은 하드코딩이 아니라 열거다.

```bash
find "$SCRIPT_DIR/profiles" -maxdepth 1 -type f -name '*.env' -printf '  %f\n' | sed 's/\.env$//' | sort
```

`profiles/`에 파일을 넣으면 코드 수정 없이 잡힌다. GNU `find`의 `-printf`에 의존한다.

동작 순서: `.env`가 있으면 `.env.backup.$(date +%Y%m%d-%H%M%S)`로 `cp` → `cp "$PROFILE_PATH" .env` → **`chmod 600 .env`**.

**두 가지 부작용**을 기억해야 한다.

- 병합이 아니라 **통째 교체**다. `.env`에 직접 추가한 `CODEX_MODEL`, `CODEX_BASE_URL`, `OPENCODE_*` 같은 항목은 `profiles/*.env`에 없으므로 사라진다(백업에는 남는다).
- `chmod 600`이므로 다른 계정이 실행하면 §2.4의 읽기 권한 검사에 걸린다.

### 4.5 `install-systemd-user.sh` (48줄)

설정 파일을 읽지 않는다. 자체 환경변수 2개를 갖는다.

| 변수 | 기본값 | 효과 |
|---|---|---|
| `SERVICE_NAME` | `vllm-qwen36.service` | 설치될 유닛 파일 이름 |
| `START_NOW` | `0` | `1`이면 설치 후 `systemctl --user restart` |
| `XDG_CONFIG_HOME` | `$HOME/.config` | 설치 경로의 베이스 |

**둘 다 기존 문서에 없다.**

동작: `systemctl` 존재 확인 → 템플릿 존재 확인 → `mkdir -p $XDG_CONFIG_HOME/systemd/user` → `sed`로 `__WORKDIR__` 치환 → `daemon-reload` → `enable` → 사용법 출력 → (`START_NOW=1`이면) `restart`.

치환 전에 `sed` 메타문자를 이스케이프한다.

```bash
escaped_dir="${SCRIPT_DIR//\\/\\\\}"
escaped_dir="${escaped_dir//&/\\&}"
sed "s|__WORKDIR__|$escaped_dir|g" "$TEMPLATE" > "$SERVICE_PATH"
```

구분자가 `|`인데 경로에 `|`가 있으면 여전히 깨진다(현실적으로 드묾).

치환 결과(dry-run):

```ini
[Unit]
Description=vLLM Qwen3.6-27B local server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/home/kms/dev/vllm-setting
Environment=PYTHONUNBUFFERED=1
ExecStart=/home/kms/dev/vllm-setting/targets/qwen36-27b-4090x2.sh
ExecStop=/home/kms/dev/vllm-setting/stop-vllm.sh
Restart=on-failure
RestartSec=10
TimeoutStopSec=60
KillMode=mixed

[Install]
WantedBy=default.target
```

`TimeoutStopSec=60`이 `TIMEOUT_SECONDS`(기본 30, `profiles/128k.env`는 45)보다 커서 `ExecStop`이 SIGKILL 단계까지 끝낼 시간이 있다. 유닛은 **Qwen3.6 타깃 전용**이며 Qwen3.8용 템플릿은 없다.

## 5. installer 2종

### 5.1 `install-codex-config.sh` (113줄)

**변수**

| 변수 | 기본값 |
|---|---|
| `CODEX_MODEL` | `$SERVED_MODEL_NAME` |
| `CODEX_BASE_URL` | `http://127.0.0.1:$PORT/v1` |
| `CODEX_PROFILE` | `qwen-local` |
| `CODEX_HOME` | `$HOME/.codex` |
| (유도) `CONFIG_PATH` | `$CODEX_HOME/config.toml` |
| (유도) `PROFILE_PATH` | `$CODEX_HOME/$CODEX_PROFILE.config.toml` |

`ENABLE_TOOL_CALLS != 1`이면 stderr에 경고만 하고 계속 진행한다.

**마이그레이션 (config.toml 정리)** — `config.toml`이 존재하고 아래 정규식 중 하나가 걸릴 때만 돈다.

```
^# --- vllm-setting managed block|^\[model_providers\.vllm\]|^\[profiles\.
```

`^\[profiles\.`는 프로필 이름과 무관하게 **모든** `[profiles.*]` 섹션을 트리거로 삼는다(사용자가 직접 쓴 다른 프로필이 있어도 백업 + 정리 경로를 탄다).

정리는 awk 3단계다.

1. `MARK_BEGIN` ~ `MARK_END` 사이 줄 제거 (마커 줄 포함).
2. `[model_providers.vllm]` 또는 `[profiles.$CODEX_PROFILE]` 섹션 제거. 다음 `^\[`를 만나면 `drop=0`으로 복귀하므로 섹션 하나만 정확히 걷어낸다.
3. 최상위(첫 `^\[` 이전) 영역에 `model_provider = "vllm"`이 있으면, 최상위의 `model =`과 `model_provider =` 줄을 제거. 아주 오래된 버전이 강제한 기본 모델을 되돌리는 단계다.

정리 전에 `config.toml.backup.$(date +%Y%m%d-%H%M%S)`를 남긴다.

**프로필 파일 생성** — 기존 파일이 있으면 백업 후 통째로 다시 쓴다. 스크래치패드로 `CODEX_HOME`을 돌려 실제 산출물을 확인했다.

```
$ CODEX_HOME=<scratch>/codexhome ./install-codex-config.sh
Wrote <scratch>/codexhome/qwen-local.config.toml
  default model:  unchanged (Codex original; config.toml not modified)
  local profile:  qwen-local -> qwen3.6-27b-fp8 @ http://127.0.0.1:8000/v1
```

```toml
# Managed by vllm-setting/install-codex-config.sh — rerun it to regenerate.
model = "qwen3.6-27b-fp8"
model_provider = "vllm"

[model_providers.vllm]
name = "vLLM local (qwen3.6-27b-fp8)"
base_url = "http://127.0.0.1:8000/v1"
# Codex >= 0.132 dropped wire_api = "chat"; the vLLM server must expose
# /v1/responses (recent vLLM versions do).
wire_api = "responses"
```

프로바이더 키는 `vllm`으로 **하드코딩**돼 있다(`CODEX_PROFILE`은 파일 이름과 프로필 이름만 바꾼다). `wire_api = "responses"`이므로 서버 쪽 vLLM이 `/v1/responses`를 노출해야 한다.

### 5.2 `install-opencode-config.sh` (86줄)

**변수**

| 변수 | 기본값 |
|---|---|
| `OPENCODE_MODEL` | `$SERVED_MODEL_NAME` |
| `OPENCODE_BASE_URL` | `http://127.0.0.1:$PORT/v1` |
| `OPENCODE_PROVIDER` | `vllm` |
| `OPENCODE_CONFIG` | `$HOME/.config/opencode/opencode.json` |

`python3`이 없으면 **exit 1**(하드 요구). `ENABLE_TOOL_CALLS != 1`은 경고만.

동작: `mkdir -p $(dirname ...)` → 기존 파일이 있으면 무조건 백업 → python3 heredoc으로 병합.

병합 스니펫의 핵심 3줄:

```python
cfg.setdefault("$schema", "https://opencode.ai/config.json")
cfg.setdefault("provider", {})[provider_key] = {
    "npm": "@ai-sdk/openai-compatible",
    "name": f"vLLM local ({model})",
    "options": {"baseURL": base_url},
    "models": {model: {"name": model}},
}
```

`setdefault`이므로 기존 `provider` 사전과 다른 키들은 보존되고, `provider_key` 항목만 통째로 교체된다. JSON 파싱 실패 시 stderr에 안내 후 `sys.exit(1)`이며 파일은 건드리지 않는다(백업은 이미 만들어진 뒤다). 출력은 `indent=2`, `ensure_ascii=False`, 끝에 개행 하나.

스크래치패드 실행 결과:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "vllm": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "vLLM local (qwen3.6-27b-fp8)",
      "options": { "baseURL": "http://127.0.0.1:8000/v1" },
      "models": { "qwen3.6-27b-fp8": { "name": "qwen3.6-27b-fp8" } }
    }
  }
}
```

Codex와 달리 Chat Completions로 붙으므로 `/v1/responses` 지원이 필요 없다.

## 6. `qwen3-coder-2080ti/` 하위 트리

루트와 파일을 공유하지 않는다. 자체 `.env`(`ENV_FILE`로 경로 변경 가능)를 4개 스크립트가 읽는다.

### 6.1 변수와 기본값

| 변수 | 기본값 | 읽는 스크립트 | `.env.example`에 있음 |
|---|---|---|:-:|
| `CUDA_VISIBLE_DEVICES` | `0,1` | run 2종 | O |
| `HOST` | `127.0.0.1` | run 2종, health-check | O |
| `SERVED_MODEL_NAME` | `qwen3-coder-30b-a3b` | run 2종, health-check | O |
| `BACKEND` | `llama` | health-check | O |
| `LLAMA_PORT` | `8080` | run-llama, health-check | O |
| `LLAMA_CTX_SIZE` | `16384` | run-llama | O |
| `LLAMA_TENSOR_SPLIT` | `1,1` | run-llama | O |
| `LLAMA_CACHE_TYPE_K` | `q8_0` | run-llama | O |
| `LLAMA_CACHE_TYPE_V` | `q8_0` | run-llama | O |
| `LLAMA_SERVER` | `$SCRIPT_DIR/llama.cpp/build/bin/llama-server` | run-llama | — |
| `MODEL_PATH` | `$SCRIPT_DIR/models/Qwen3-Coder-30B-A3B-Instruct-Q4_K_S.gguf` | run-llama, download-gguf | — |
| `LLAMA_PID_FILE` | `$SCRIPT_DIR/llama-server.pid` | run-llama, stop-server | — |
| `VLLM_PORT` | `8000` | run-vllm, health-check | O |
| `VLLM_MODEL` | `cyankiwi/Qwen3-Coder-30B-A3B-Instruct-AWQ-4bit` | run-vllm | O |
| `VLLM_MAX_MODEL_LEN` | `8192` | run-vllm | O |
| `VLLM_GPU_MEMORY_UTILIZATION` | `0.92` | run-vllm | O |
| `VLLM_MAX_NUM_BATCHED_TOKENS` | `2048` | run-vllm | O |
| `VLLM_TP_SIZE` | `2` | run-vllm | **없음** |
| `VLLM_PID_FILE` | `$SCRIPT_DIR/vllm-server.pid` | run-vllm, stop-server | — |
| `VLLM_BIN` | 자동 탐색 (`PATH` → `.venv-vllm/bin/vllm`) | run-vllm | — |
| `WAIT_READY_SECONDS` | `600` | health-check | O |
| `REQUEST_TIMEOUT` | `180` | health-check | O |
| `TIMEOUT_SECONDS` | `30` | stop-server | **없음** |
| `BASE_URL` | 유도값 | health-check | — |
| `LLAMA_CPP_DIR` | `$SCRIPT_DIR/llama.cpp` | install-llama-cpp | — |
| `BUILD_DIR` | `$LLAMA_CPP_DIR/build` | install-llama-cpp | — |
| `CUDA_ARCHITECTURES` | `75` | install-llama-cpp | — |
| `BUILD_JOBS` | `$(nproc)` | install-llama-cpp | — |
| `MODEL_DIR` | `$SCRIPT_DIR/models` | download-gguf | — |
| `GGUF_QUANT` | `Q4_K_S` | download-gguf | — |
| `GGUF_FILE` | `Qwen3-Coder-30B-A3B-Instruct-${GGUF_QUANT}.gguf` | download-gguf | — |
| `GGUF_REPO` | `unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF` | download-gguf | — |

### 6.2 스크립트별 요점

**`install-llama-cpp.sh`** — `git`·`cmake`·`nvcc` 존재를 확인하고, `llama.cpp` 디렉터리가 git 체크아웃이면 `fetch` + `pull --ff-only`, 아무것도 없으면 `git clone --depth 1 https://github.com/ggml-org/llama.cpp.git`, git이 아닌 무언가가 있으면 exit 1. 빌드는 `-DGGML_CUDA=ON -DLLAMA_CURL=ON -DCMAKE_CUDA_ARCHITECTURES=75 -DCMAKE_BUILD_TYPE=Release`, 타깃은 `llama-server llama-cli`.

**`download-gguf.sh`** — URL은 `https://huggingface.co/${GGUF_REPO}/resolve/main/${GGUF_FILE}?download=true`. 이미 파일이 있으면(`-s`) 즉시 exit 0. 받을 때는 `curl --fail --location --retry 5 --retry-delay 3 --continue-at -`로 `.part`에 받고 완료 후 `mv`한다.

**`run-llama-server.sh`** — 사전 점검 4개: `llama-server` 실행 가능 / GGUF 존재(`-s`) / `nvidia-smi`와 GPU 개수·인덱스 / 포트 점유. `TP_SIZE` 개념이 없어 GPU 개수 검사는 `CUDA_VISIBLE_DEVICES` 항목 수만 본다. `/dev/shm`·디스크 경고는 **없다**. 인자에는 설정값 외에 하드코딩된 샘플링 파라미터가 들어간다.

```
--n-gpu-layers all --split-mode layer --flash-attn auto --parallel 1 --jinja
--temp 0.7 --top-p 0.8 --top-k 20 --repeat-penalty 1.05
```

**`run-vllm-server.sh`** — 사전 점검 4개: vllm 실행파일(`PATH` → `.venv-vllm/bin/vllm`) / GPU / VRAM(`< 10000` MiB면 exit 1) / 포트. 버전·compute capability 검사는 없다. 인자 중 상당수가 하드코딩이다.

```
--enable-expert-parallel --max-num-seqs 1 --dtype half --kv-cache-dtype auto
--enable-prefix-caching --enable-chunked-prefill --disable-custom-all-reduce
--enforce-eager --enable-auto-tool-choice --tool-call-parser qwen3_coder
```

`--dtype half`와 `--enforce-eager`가 Turing 대응의 핵심이고, 루트 타깃과 달리 `--reasoning-parser`가 없다.

**`health-check.sh`** — `BACKEND`가 `llama`면 `LLAMA_PORT`, `vllm`이면 `VLLM_PORT`, 그 외면 `BACKEND must be llama or vllm.`으로 exit 1. 루트 판과 달리 `CHAT_CHECK` 스위치가 없어 chat 요청을 항상 보내고, 임시 파일도 2개(본문을 파일로 쓰지 않고 `-d` 인라인)다. 폴링은 `until` 루프.

**`stop-server.sh`** — PID 파일 2개(`LLAMA_PID_FILE`, `VLLM_PID_FILE`)를 순회한다. 루트 판과 달리 `ss`·`ps` 폴백이 없고, 대신 **프로세스 그룹**을 먼저 노린다.

```bash
kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
```

`-$pid`는 PID를 프로세스 그룹 ID로 해석한다. run 스크립트가 `setsid`를 쓰지 않으므로 대개 그룹 리더가 아니어서 첫 시도가 실패하고 두 번째 폴백이 동작한다. 순회 끝에 PID 파일은 항상 `rm -f`된다.

## 7. 설정 스키마 전체

### 7.1 루트 `.env` — 모델·서버

| 변수 | 내장 기본값 | `.env.example` | 읽는 스크립트 |
|---|---|:-:|---|
| `MODEL` | `Qwen/Qwen3.6-27B-FP8` | O | qwen36 타깃, stop-vllm |
| `SERVED_MODEL_NAME` | `qwen3.6-27b-fp8` | O | qwen36 타깃, stop-vllm, health-check, benchmark, installer 2종 |
| `HOST` | `0.0.0.0` | O | qwen36 타깃, health-check, benchmark |
| `PORT` | `8000` | O | 전부 (installer 포함) |
| `CUDA_VISIBLE_DEVICES` | `0,1` | O | qwen36 타깃 |
| `TP_SIZE` | `2` | O | qwen36 타깃 |
| `DTYPE` | `auto` | **없음** | qwen36 타깃 |
| `PID_FILE` | `<repo>/vllm.pid` | **없음** | qwen36 타깃, stop-vllm |
| `VLLM_BIN` | 자동 탐색 | **없음** | 타깃 3종 |
| `ENV_FILE` | 타깃별 경로 | **없음** | qwen38 타깃 2종만 |

### 7.2 루트 `.env` — 메모리·컨텍스트

| 변수 | 내장 기본값 | `.env.example` |
|---|---|:-:|
| `MAX_MODEL_LEN` | `65536` | O |
| `GPU_MEMORY_UTILIZATION` | `0.90` | O |
| `MAX_NUM_SEQS` | `2` | O |
| `MAX_NUM_BATCHED_TOKENS` | `8192` | O |
| `KV_CACHE_DTYPE` | `auto` | O |

### 7.3 루트 `.env` — 기능 스위치 (문자열 `"1"`만 켜짐)

| 변수 | 내장 기본값 | `.env.example` | 붙는 인자 |
|---|---|:-:|---|
| `ENABLE_PREFIX_CACHING` | `1` | O | `--enable-prefix-caching` |
| `ENABLE_CHUNKED_PREFILL` | `1` | O | `--enable-chunked-prefill` |
| `DISABLE_CUSTOM_ALL_REDUCE` | `1` | O | `--disable-custom-all-reduce` |
| `ENABLE_TOOL_CALLS` | `1` | O | `--enable-auto-tool-choice --tool-call-parser qwen3_coder` |
| `TRUST_REMOTE_CODE` | `0` | O | `--trust-remote-code` |
| `LANGUAGE_MODEL_ONLY` | h100=`0`, 4090=`1`, qwen36=해당 없음 | **없음** | `--language-model-only` |
| `ENABLE_MTP` | `0` (h100만) | **없음** | `--speculative-config {...}` |
| `MTP_NUM_SPECULATIVE_TOKENS` | `3` (h100만) | **없음** | 위 JSON 안의 값 |

`LANGUAGE_MODEL_ONLY`·`ENABLE_MTP`·`MTP_NUM_SPECULATIVE_TOKENS`는 `targets/*.env.example`에는 들어 있다.

### 7.4 루트 `.env` — 보조 스크립트

| 변수 | 내장 기본값 | `.env.example` | 읽는 스크립트 |
|---|---|:-:|---|
| `TIMEOUT_SECONDS` | `30` | O (`128k`는 45) | stop-vllm |
| `WAIT_READY_SECONDS` | `300` | O (`128k`는 420) | health-check |
| `REQUEST_TIMEOUT` | health-check `120` / benchmark `180` | O = `120` (`128k`는 180) | health-check, benchmark |
| `CHAT_CHECK` | `1` | O | health-check |
| `BENCH_MAX_TOKENS` | `512` | **없음** | benchmark |
| `BASE_URL` | `http://$CLIENT_HOST:$PORT/v1` | **없음** | health-check, benchmark |
| `CODEX_MODEL` | `$SERVED_MODEL_NAME` | 주석 처리 | install-codex |
| `CODEX_BASE_URL` | `http://127.0.0.1:$PORT/v1` | 주석 처리 | install-codex |
| `CODEX_PROFILE` | `qwen-local` | **없음** | install-codex |
| `CODEX_HOME` | `$HOME/.codex` | **없음** | install-codex |
| `OPENCODE_MODEL` | `$SERVED_MODEL_NAME` | **없음** | install-opencode |
| `OPENCODE_BASE_URL` | `http://127.0.0.1:$PORT/v1` | **없음** | install-opencode |
| `OPENCODE_PROVIDER` | `vllm` | **없음** | install-opencode |
| `OPENCODE_CONFIG` | `$HOME/.config/opencode/opencode.json` | **없음** | install-opencode |
| `SERVICE_NAME` | `vllm-qwen36.service` | **없음** | install-systemd-user |
| `START_NOW` | `0` | **없음** | install-systemd-user |
| `HF_HOME` | `$HOME/.cache/huggingface` (읽기만) | **없음** | 타깃 3종 (디스크 경고) |
| `XDG_CONFIG_HOME` | `$HOME/.config` (읽기만) | **없음** | install-systemd-user |

### 7.5 명령줄 오버라이드가 통하는가 (실측)

§2.3의 클로버링 때문에, **`.env`(또는 해당 타깃의 `.env`)에 그 줄이 있으면 명령줄 값은 무시된다.**

| 상태 | 변수 | 명령줄 오버라이드 |
|---|---|---|
| `.env.example`을 그대로 복사한 `.env`가 있을 때 | `MODEL`, `SERVED_MODEL_NAME`, `CUDA_VISIBLE_DEVICES`, `TP_SIZE`, `HOST`, `PORT`, `MAX_MODEL_LEN`, `KV_CACHE_DTYPE`, `GPU_MEMORY_UTILIZATION`, `MAX_NUM_SEQS`, `MAX_NUM_BATCHED_TOKENS`, `ENABLE_PREFIX_CACHING`, `ENABLE_CHUNKED_PREFILL`, `DISABLE_CUSTOM_ALL_REDUCE`, `ENABLE_TOOL_CALLS`, `TRUST_REMOTE_CODE`, `TIMEOUT_SECONDS`, `WAIT_READY_SECONDS`, `REQUEST_TIMEOUT`, `CHAT_CHECK` | **통하지 않음** (20개) |
| 같은 상태 | `DTYPE`, `PID_FILE`, `VLLM_BIN`, `BASE_URL`, `BENCH_MAX_TOKENS`, `ENV_FILE`, `CODEX_*` 4개, `OPENCODE_*` 4개, `SERVICE_NAME`, `START_NOW`, `LANGUAGE_MODEL_ONLY`, `ENABLE_MTP`, `MTP_NUM_SPECULATIVE_TOKENS` | **통함** (`.env.example`에 줄이 없으므로) |
| `.env`가 아예 없을 때 | 전부 | **통함** |
| `agents.md` 방법 A대로 `.env`에 `CODEX_MODEL`을 넣은 뒤 | `CODEX_MODEL` | **통하지 않게 바뀜** — 방법 B가 그때부터 무력화 |

## 8. 실측 대조표 — 기존 문서 서술 vs 실제 코드

기존 문서는 수정하지 않았다. 아래는 실행·읽기로 확인한 차이만 적은 것이다.

| # | 출처 | 문서 서술 | 실제 | 근거 |
|---:|---|---|---|---|
| 1 | `design.md:18`, `targets.md:98,126`, `targets/*.env.example` 말미 | "값을 명령줄로 넘겨야 합니다" / `PORT=8000 SERVED_MODEL_NAME=qwen3.8-27b ./health-check.sh` | `.env`가 존재하면 **명령줄 값이 무시된다.** `set -a; source .env`의 평문 대입이 환경을 덮어씀 | `PORT=9999 ./health-check.sh` → `Checking vLLM at http://127.0.0.1:8000/v1`; `SERVED_MODEL_NAME=qwen3.8-27b ./benchmark-smoke.sh` → `Model: qwen3.6-27b-fp8` |
| 2 | `design.md:14` | "`.env`는 … `use-profile.sh` … 가 전부 이 파일을 봅니다" | `use-profile.sh`는 `.env`를 `source`하지 않는다. 백업 후 덮어쓸 뿐 | `grep -n source use-profile.sh` → 무출력 |
| 3 | `config.md:4` | `"실행 가이드 > 2. 최초 설정"의 항목별 점검대로` | 그런 섹션이 레포에 없다 | `grep -rn "실행 가이드" .` → 이 문장 자신만 히트 |
| 4 | `targets.md:38-42` | 사전 점검 7번(compute capability)은 "4090 타깃"에 적용 | `qwen38-27b-4090x2.sh`에만 있고 **`qwen36-27b-4090x2.sh`에는 없다.** 후자도 FP8 체크포인트를 서빙한다 | 두 스크립트 정독 (§3.2) |
| 5 | `targets.md:74`, `config.md` | qwen36의 `--language-model-only`를 "기본 적용되는 플래그"로 서술 | `qwen36-27b-4090x2.sh`에는 `LANGUAGE_MODEL_ONLY` 변수 자체가 없어 **끌 수 없다.** 다른 두 타깃은 변수로 제어됨 | `qwen36-27b-4090x2.sh:147` (조건 없는 배열 원소) |
| 6 | `config.md:46` | `REQUEST_TIMEOUT` = `120`(헬스 체크) / `180`(벤치마크) | 180은 **스크립트 내장 기본값**일 뿐, `.env.example`·`profiles/64k.env`가 `120`을 담고 있어 기본 설정에서는 벤치마크도 120 | `.env.example:35`, `benchmark-smoke.sh:23` |
| 7 | `config.md:49` | `BASE_URL` 기본값 `http://127.0.0.1:$PORT/v1` | `127.0.0.1`은 `HOST`가 `0.0.0.0`·`::`일 때만. 그 외에는 `HOST` 값을 그대로 씀 | `health-check.sh:27-33`, `benchmark-smoke.sh:26-32` |
| 8 | `config.md` 표 전체 | `.env` 항목 목록 | `DTYPE`·`PID_FILE`·`VLLM_BIN`·`BASE_URL`·`BENCH_MAX_TOKENS`는 문서에 있으나 **`.env.example`에는 없다.** 반대로 `ENV_FILE`·`SERVICE_NAME`·`START_NOW`·`VLLM_TP_SIZE`는 **문서에도 `.env.example`에도 없다** | §7 |
| 9 | `README.md:87` | "`*.pid` … `.gitignore`로 제외" | 범용 `*.pid` 규칙이 없다. `vllm.pid`, `vllm-qwen38-*.pid`, `qwen3-coder-2080ti/*.pid` 3개뿐 | `git check-ignore -v custom.pid` → 무출력 |
| 10 | `README.md:27` 빠른 시작 | `chmod +x *.sh targets/*.sh` | 16개 전부 이미 `100755`로 추적된다. 불필요(무해) | `git ls-files -s` |
| 11 | `scripts.md:23` | `use-profile.sh`가 `.env`를 `chmod 600` 처리 | 맞음. 다만 타깃 스크립트의 권한 에러 안내는 `chmod 644`라 프로필 재활성화 시 원복된다 | `use-profile.sh:40` vs `targets/*.sh:12` |
| 12 | `scripts.md:36` | "agents.md의 **Codex CLI > 환경 변수로 설정 바꾸기**" | agents.md에서 "환경 변수로 설정 바꾸기"는 `##` 최상위 절 | `grep -n '^#' docs/agents.md` |
| 13 | `qwen38-27b-4090x2.sh:128` (에러 메시지) | `(see the 2080 Ti section of README.md)` | README에 2080 Ti 섹션이 없다. 실제 안내는 `docs/targets.md#qwen3-coder-2080ti` | `grep -n '^#' README.md` |
| 14 | `design.md:27-54` 흐름도 | installer로 `install-codex-config.sh`만 표시 | `install-opencode-config.sh`도 `.env`를 읽는 동급 노드 | `install-opencode-config.sh:15-20` |
| 15 | `.env` 파일 상태 | — | 작업 트리의 `.env`는 `.env.example`과 **바이트 단위로 동일**하다 (`diff` 무출력, 둘 다 1,119바이트) | `diff .env .env.example` |

## 9. 진입점부터의 호출 흐름

**서버 기동 (Qwen3.6, 수동)**

```
사용자
 └─ ./targets/qwen36-27b-4090x2.sh
     ├─ source <repo>/.env                       (있으면)
     ├─ preflight 1..5  → 실패 시 exit 1
     │   ├─ command -v vllm / [[ -x .venv/bin/vllm ]]
     │   ├─ nvidia-smi --list-gpus
     │   ├─ nvidia-smi --query-gpu=memory.total
     │   └─ ss -tln | awk | grep
     ├─ preflight 6     → df -k /dev/shm, df -BG $HOME   (경고만)
     ├─ args=( ... )    조립
     ├─ heredoc 요약 출력
     ├─ echo $$ > <repo>/vllm.pid
     └─ exec $VLLM_BIN serve ... "$@"            (프로세스 교체)
```

**서버 기동 (systemd)**

```
systemctl --user start vllm-qwen36.service
 └─ ExecStart=<repo>/targets/qwen36-27b-4090x2.sh    (위와 동일 경로)
systemctl --user stop vllm-qwen36.service
 └─ ExecStop=<repo>/stop-vllm.sh                     (TimeoutStopSec=60 안에서)
```

**검증**

```
./health-check.sh
 ├─ source <repo>/.env
 ├─ mktemp x3 + trap EXIT
 ├─ loop: curl $BASE_URL/models   (2초 간격, WAIT_READY_SECONDS까지)
 └─ CHAT_CHECK=1 → curl $BASE_URL/chat/completions → jq (있으면)
```

**종료**

```
./stop-vllm.sh
 ├─ source <repo>/.env
 ├─ 경로1: PID 파일 → kill -0 → ps -p 로 cmdline 검증 → add_pid
 ├─ 경로2: ss -H -ltnp "sport = :$PORT" → sed → add_pid
 ├─ 경로3: ps -eo pid=,args= → *vllm* && *serve* && (*PORT*|*MODEL*|*NAME*) → add_pid
 ├─ 각 pid: collect_descendants (pgrep -P 재귀)
 ├─ kill -TERM 일괄 → 1초 폴링 x TIMEOUT_SECONDS
 └─ 남으면 kill -KILL → rm -f PID_FILE
```

**에이전트 연결**

```
./install-codex-config.sh
 ├─ source <repo>/.env
 ├─ (조건부) config.toml 백업 + awk 3단계 정리
 └─ $CODEX_HOME/$CODEX_PROFILE.config.toml 백업 + 재생성

./install-opencode-config.sh
 ├─ source <repo>/.env
 ├─ python3 존재 확인 (없으면 exit 1)
 ├─ opencode.json 백업
 └─ python3 heredoc → provider.<키>만 교체하고 저장
```

**프로필 전환**

```
./use-profile.sh 128k
 ├─ profiles/128k.env 존재 확인
 ├─ .env → .env.backup.<타임스탬프>
 ├─ cp profiles/128k.env .env
 └─ chmod 600 .env
```

## 10. 의존 관계

### 10.1 외부 명령

| 명령 | 필수/선택 | 쓰는 곳 | 없을 때 |
|---|---|---|---|
| `bash` 4+ | 필수 | 전부 | — |
| `nvidia-smi` | 필수 | run 스크립트 5개 | exit 1 (명시적 에러) |
| `ss` (iproute2) | 필수/선택 | 포트 점검(run), 종료 경로2(stop) | run: 점검이 조용히 통과 / stop: 경로2 건너뜀 |
| `ps`, `pgrep` | 필수 | `stop-vllm.sh`, `stop-server.sh` | 종료 경로 실패 |
| `curl` | 필수 | health-check 2종, benchmark, download-gguf | 명시적 에러 후 exit 1 |
| `jq` | **선택** | health-check 2종 | 응답 본문 출력만 생략 |
| `python3` | 필수 | `install-opencode-config.sh` | exit 1 |
| `systemctl` | 필수 | `install-systemd-user.sh` | exit 1 |
| `git`, `cmake`, `nvcc` | 필수 | `install-llama-cpp.sh` | exit 1 |
| `awk`, `sed`, `grep`, `sort`, `head`, `tr`, `wc`, `df`, `date`, `mktemp`, `find`, `cp`, `mv`, `mkdir`, `chmod`, `rm` | 필수 | 전반 | — |
| `nproc` | 필수 | `install-llama-cpp.sh` (`BUILD_JOBS`) | — |
| `vllm` | 필수 | 타깃 3종, 2080ti vLLM 경로 | exit 1 (설치 안내 포함) |
| `llama-server` | 필수 | `run-llama-server.sh` | exit 1 |

GNU 확장에 의존하는 곳: `find -printf`(use-profile), `df -BG --output=avail`(타깃 3종), `date +%s%3N`(benchmark), `grep -oE`·`sort -V`(버전 비교).

### 10.2 내부 의존

- `targets/*.sh` → 설정 파일. 다른 스크립트를 호출하지 않는다.
- `stop-vllm.sh` / `health-check.sh` / `benchmark-smoke.sh` → 루트 `.env`만. 서로 호출하지 않는다.
- `install-systemd-user.sh` → `systemd/vllm-qwen36.service.in`(없으면 exit 1) → 간접적으로 `targets/qwen36-27b-4090x2.sh`, `stop-vllm.sh`.
- `use-profile.sh` → `profiles/*.env`.
- `qwen3-coder-2080ti/*` → 같은 디렉터리 안에서만 서로 참조(`stop-server.sh`가 run 스크립트가 만든 PID 파일 2개를 읽음).
- 루트와 `qwen3-coder-2080ti/` 사이에는 **코드 의존이 전혀 없다.**

### 10.3 외부 서비스

| 대상 | 접근 주체 | 시점 |
|---|---|---|
| HuggingFace Hub (모델) | `vllm serve` 내부 | 최초 기동 |
| `huggingface.co/.../resolve/main/*.gguf` | `download-gguf.sh` | 명시적 실행 |
| `github.com/ggml-org/llama.cpp.git` | `install-llama-cpp.sh` | 명시적 실행 |
| `opencode.ai/config.json` (JSON 스키마 URL) | 문자열로만 기록 | 네트워크 접근 없음 |

## 11. 검증 실행 기록

부작용이 없는 명령만 실행했다. 모델 서빙 기동, GPU 연산, 사용자 홈의 설정 파일 수정은 하지 않았다.

**문법 검사 — 16/16 통과**

```
$ for f in $(find . -name '*.sh'); do bash -n "$f"; done
./benchmark-smoke.sh                          OK
./health-check.sh                             OK
./install-codex-config.sh                     OK
./install-opencode-config.sh                  OK
./install-systemd-user.sh                     OK
./qwen3-coder-2080ti/download-gguf.sh         OK
./qwen3-coder-2080ti/health-check.sh          OK
./qwen3-coder-2080ti/install-llama-cpp.sh     OK
./qwen3-coder-2080ti/run-llama-server.sh      OK
./qwen3-coder-2080ti/run-vllm-server.sh       OK
./qwen3-coder-2080ti/stop-server.sh           OK
./stop-vllm.sh                                OK
./targets/qwen36-27b-4090x2.sh                OK
./targets/qwen38-27b-4090x2.sh                OK
./targets/qwen38-27b-h100x2.sh                OK
./use-profile.sh                              OK
```

`shellcheck`는 이 머신에 설치돼 있지 않아 실행하지 못했다.

**그 밖에 실행한 것** — `use-profile.sh` 3경로(§4.4), 타깃 3종 사전 점검 1단계와 `VLLM_BIN=/bin/false`로 4단계까지(§3.2), `stop-vllm.sh` 2회(§4.1), `health-check.sh`·`benchmark-smoke.sh` 클로버링 확인(§2.3, §4.3), installer 2종을 스크래치패드 경로로(§5), systemd 템플릿 `sed` 치환 dry-run(§4.5), `git check-ignore`(§8 #9), `diff .env .env.example`(§8 #15).

**실행 환경** — bash 5.2.21, GPU는 RTX 3050 1장(6 GiB), `vllm` 미설치, `.venv` 없음, 8000·8080 포트 모두 비어 있음, 실행 중인 `vllm serve` 프로세스 없음. 따라서 타깃 스크립트는 사전 점검 1단계(또는 `VLLM_BIN` 지정 시 4단계)에서 멈췄고 VRAM·포트 검사 이후는 도달하지 않았다. 모델 서빙 기동과 GPU 연산은 수행하지 않았다.
