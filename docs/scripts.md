# 보조 스크립트

서빙 타깃과 무관하게 공통으로 쓰는 스크립트들입니다. 타깃별 실행 스크립트는 [targets.md](targets.md)를 보세요.

## `recommend-settings.sh` — 하드웨어별 타깃 추천

- `nvidia-smi`, `/proc/meminfo`, `nproc`, `df`로 GPU별 전체/여유 VRAM,
  compute capability, RAM, CPU, `/dev/shm`, 디스크 여유를 감지합니다.
- 추적 타깃 4개를 `perfect/good/marginal/too_tight`로 평가합니다. 전체 용량과
  현재 여유 VRAM을 분리해 `ready`도 함께 표시합니다.
- `system`, `recommend`(기본), `plan TARGET` 명령과 `--json`을 지원합니다.
- `--gpu-count`, `--gpu-name`, `--vram-mib`, `--free-vram-mib`,
  `--compute-cap`, `--ram-gib`, `--cpu-cores`로 다른 머신을 시뮬레이션합니다.
- 읽기 전용입니다. `.env`를 쓰거나 runner를 실행하지 않습니다.

```bash
./recommend-settings.sh
./recommend-settings.sh system --json | jq .
./recommend-settings.sh plan qwen38-27b-h100x2
./tests/recommend-settings-test.sh
```

판정 기준과 llmfit 비교는 [llmfit-comparison.md](llmfit-comparison.md)를 봅니다.

## `stop-vllm.sh` — 안전한 종료

- `vllm.pid` → 포트 리스너(`ss`) → 프로세스 목록(`ps`) 순으로 vLLM 프로세스를 찾고, 자식 워커까지 재귀적으로 수집합니다.
- SIGTERM 후 `TIMEOUT_SECONDS`(기본 30초) 대기, 남으면 SIGKILL로 GPU 메모리를 확실히 반환합니다.

## `health-check.sh` — 헬스 체크

- `/v1/models`가 준비될 때까지(기본 최대 300초) 폴링한 뒤, 짧은 chat completion 요청까지 보내 실제 응답을 확인합니다.
- `CHAT_CHECK=0`이면 models 엔드포인트 확인만 수행합니다.

## `benchmark-smoke.sh` — 스모크 벤치마크

- 코딩 프롬프트 3종(binary-search, bug-review, lru-cache)을 순차 실행해 latency, completion token 수, 초당 토큰(tok/s)을 출력합니다.
- `nvidia-smi`가 있으면 실행 전후 GPU 메모리도 함께 표시합니다. `BENCH_MAX_TOKENS`로 생성 토큰 수 조절.

## `use-profile.sh` — 실행 프로필 전환

- `profiles/64k.env`(안정 기본값), `profiles/128k.env`(롱 컨텍스트)를 `.env`로 복사해 활성화합니다.
- 기존 `.env`는 타임스탬프 백업(`.env.backup.*`) 후 교체하고, 새 `.env`는 `chmod 600` 처리합니다.

## `install-systemd-user.sh` — systemd user 서비스 설치

- `systemd/vllm-qwen36.service.in` 템플릿의 `__WORKDIR__`을 현재 체크아웃 경로로 치환해 `~/.config/systemd/user/vllm-qwen36.service`로 설치하고 enable까지 수행합니다.
- 서비스는 `ExecStart`에 run 스크립트, `ExecStop`에 stop 스크립트를 사용하며 `Restart=on-failure`입니다.

## `install-codex-config.sh` — Codex CLI에 로컬 서버 등록

- `.env`의 `SERVED_MODEL_NAME`/`PORT`를 읽어 로컬 vLLM 서버를 **Codex 프로필 파일** `~/.codex/qwen-local.config.toml`로 등록합니다. **Codex의 기본 모델은 건드리지 않습니다** — 그냥 `codex`는 원래 모델로 뜨고, 로컬 모델은 `codex --profile qwen-local`로 씁니다.
- 최신 Codex는 `config.toml` 안의 `[profiles.*]` 섹션을 허용하지 않고 프로필별 별도 파일(`<이름>.config.toml`)을 요구하므로, 이 스크립트는 **`config.toml`을 건드리지 않습니다**. 단, 구버전 스크립트가 config.toml에 심어둔 블록(관리 블록·기본 모델 강제)이 발견되면 백업 후 제거해서 Codex가 다시 시작되게 합니다.
- 기존 프로필 파일이 있으면 타임스탬프 백업(`*.backup.*`) 후 재생성합니다.
- `ENABLE_TOOL_CALLS=0`으로 꺼져 있으면 경고를 출력합니다(Codex는 tool calling이 필수).
- `CODEX_MODEL`/`CODEX_BASE_URL`/`CODEX_PROFILE`/`CODEX_HOME`으로 대상을 바꿀 수 있습니다 — 방법은 [agents.md](agents.md)의 "Codex CLI > 환경 변수로 설정 바꾸기" 참고.

## `install-opencode-config.sh` — OpenCode에 로컬 서버 등록

- `.env`의 `SERVED_MODEL_NAME`/`PORT`를 읽어 OpenCode 전역 설정(`~/.config/opencode/opencode.json`)에 로컬 vLLM 서버를 프로바이더로 등록합니다. **OpenCode의 기본 모델은 건드리지 않습니다.**
- 기존 설정을 보존합니다: JSON을 파싱해 `provider.vllm` 항목만 갱신하고 나머지 키(기본 모델, 테마, 다른 프로바이더)는 그대로 둡니다. 기존 JSON이 깨져 있으면 아무것도 바꾸지 않고 에러를 냅니다. 타임스탬프 백업도 남깁니다.
- OpenCode는 OpenAI 호환(Chat Completions) 방식으로 붙으므로 Codex와 달리 vLLM의 `/v1/responses` 지원이 필요 없습니다.
- `OPENCODE_MODEL`/`OPENCODE_BASE_URL`/`OPENCODE_PROVIDER`/`OPENCODE_CONFIG`로 대상을 바꿀 수 있습니다(JSON 병합에 python3 필요).

## systemd user 서비스

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
