#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ADVISOR="$REPO_ROOT/recommend-settings.sh"

command -v jq >/dev/null 2>&1 || {
  echo "SKIP: jq is required for recommend-settings JSON tests." >&2
  exit 77
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_jq() {
  local json="$1"
  local filter="$2"
  local label="$3"
  jq -e "$filter" >/dev/null <<< "$json" || fail "$label"
}

assert_file_contains() {
  local file="$1"
  local text="$2"
  local label="$3"
  grep -Fq -- "$text" "$file" || fail "$label"
}

simulate() {
  local count="$1"
  local name="$2"
  local vram="$3"
  local free="$4"
  local cc="$5"
  "$ADVISOR" recommend --json \
    --gpu-count "$count" \
    --gpu-name "$name" \
    --vram-mib "$vram" \
    --free-vram-mib "$free" \
    --compute-cap "$cc" \
    --ram-gib 128 \
    --cpu-cores 32
}

bash -n "$ADVISOR"

tmp_dir="$(mktemp -d)"
fake_smi="$tmp_dir/nvidia-smi"
trap 'rm -f "$fake_smi"; rmdir "$tmp_dir"' EXIT
cat > "$fake_smi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' \
  '0, NVIDIA GeForce RTX 4090, 24564, 24564, 8.9' \
  '1, NVIDIA GeForce RTX 3090, 16384, 16384, 8.6'
EOF
chmod +x "$fake_smi"

json="$(NVIDIA_SMI_BIN="$fake_smi" "$ADVISOR" recommend --json)"
assert_jq "$json" '.system.gpu_count == 2 and .system.gpus[1].vram_mib == 16384' "mixed GPU detection"
assert_jq "$json" '.targets[] | select(.id == "qwen38-27b-4090x2") | .fit == "too_tight"' "weakest GPU controls fit"

cat > "$fake_smi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' \
  '0, NVIDIA GeForce RTX 4090, 24564, 24564, 8.9' \
  '1, NVIDIA Future GPU, 24564, 24564, '
EOF
json="$(NVIDIA_SMI_BIN="$fake_smi" "$ADVISOR" recommend --json)"
assert_jq "$json" '.targets[] | select(.id == "qwen38-27b-4090x2") | .fit == "marginal" and .ready == false' "unknown CC blocks readiness"

json="$(simulate 2 'NVIDIA GeForce RTX 4090' 24564 24564 8.9)"
assert_jq "$json" '.recommendation == "qwen38-27b-4090x2"' "4090 recommendation"
assert_jq "$json" '.targets[] | select(.id == "qwen38-27b-4090x2") | .fit == "perfect" and .ready == true' "4090 perfect fit"
while IFS= read -r runner; do
  [[ -x "$REPO_ROOT/${runner#./}" ]] || fail "catalog runner is missing or not executable: $runner"
done < <(jq -r '.targets[].runner' <<< "$json")

json="$(simulate 2 'NVIDIA H100 80GB HBM3' 81920 81920 9.0)"
assert_jq "$json" '.recommendation == "qwen38-27b-h100x2"' "H100 recommendation"
assert_jq "$json" '.targets[] | select(.id == "qwen38-27b-h100x2") | .settings.max_model_len == 262144' "H100 context"

json="$(simulate 2 'NVIDIA GeForce RTX 2080 Ti' 11264 11264 7.5)"
assert_jq "$json" '.recommendation == "qwen3-coder-2080ti"' "2080 Ti recommendation"
assert_jq "$json" '.targets[] | select(.id == "qwen3-coder-2080ti") | .backend == "llama.cpp"' "2080 Ti backend"

json="$(simulate 1 'NVIDIA GeForce RTX 3050' 6144 5000 8.6)"
assert_jq "$json" '.recommendation == null' "3050 has no supported target"
assert_jq "$json" '[.targets[].fit] | all(. == "too_tight")' "3050 targets are too tight"

json="$(simulate 2 'NVIDIA GeForce RTX 4090' 24564 1000 8.9)"
assert_jq "$json" '.recommendation == "qwen38-27b-4090x2"' "busy 4090 capacity recommendation"
assert_jq "$json" '.targets[] | select(.id == "qwen38-27b-4090x2") | .fit == "marginal" and .ready == false' "busy 4090 readiness"

json="$($ADVISOR plan qwen38-27b-4090x2 --json \
  --gpu-count 2 --gpu-name 'NVIDIA GeForce RTX 4090' \
  --vram-mib 24564 --free-vram-mib 24564 --compute-cap 8.9)"
assert_jq "$json" '.target.runner == "./targets/qwen38-27b-4090x2.sh"' "plan runner"
assert_jq "$json" '.target.settings.kv_cache_dtype == "auto"' "plan KV dtype"

assert_file_contains "$REPO_ROOT/targets/qwen38-27b-4090x2.sh" \
  'MAX_MODEL_LEN="${MAX_MODEL_LEN:-65536}"' "4090 context catalog drift"
assert_file_contains "$REPO_ROOT/targets/qwen38-27b-4090x2.sh" \
  'KV_CACHE_DTYPE="${KV_CACHE_DTYPE:-auto}"' "4090 KV catalog drift"
assert_file_contains "$REPO_ROOT/targets/qwen38-27b-h100x2.sh" \
  'MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"' "H100 context catalog drift"
assert_file_contains "$REPO_ROOT/targets/qwen38-27b-h100x2.sh" \
  'KV_CACHE_DTYPE="${KV_CACHE_DTYPE:-fp8}"' "H100 KV catalog drift"
assert_file_contains "$REPO_ROOT/qwen3-coder-2080ti/run-llama-server.sh" \
  'CTX_SIZE="${LLAMA_CTX_SIZE:-16384}"' "2080 Ti context catalog drift"

if "$ADVISOR" --gpu-count nope >/dev/null 2>&1; then
  fail "invalid gpu count should fail"
fi

json="$("$ADVISOR" system --json --gpu-count 0 --gpu-name 'NVIDIA GeForce RTX 4090')"
assert_jq "$json" '.gpu_count == 0 and (.gpus | length) == 0' "explicit zero GPU count"

if "$ADVISOR" plan missing-target >/dev/null 2>&1; then
  fail "unknown target should fail"
fi

echo "recommend-settings tests: PASS"
