"""End to end: the real panel process, a fake engine target, both supervisors."""
import json
import os
import socket
import subprocess
import sys
import time
import uuid
from pathlib import Path

import httpx
import pytest
import yaml

CONTROL = Path(__file__).resolve().parents[1]
SUPERVISORS = ["local"]
if subprocess.run(["systemctl", "--user", "is-system-running"], capture_output=True, text=True).stdout.strip() \
        not in ("", "offline"):
    SUPERVISORS.append("systemd")


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class Panel:
    def __init__(self, home, supervisor):
        self.home, self.supervisor = home, supervisor
        self.port = free_port()
        self.proc = None

    def up(self):
        env = {**os.environ, "LLMCTL_HOME": str(self.home), "LLMCTL_PORT": str(self.port),
               "LLMCTL_SCRIPTS": "control/tests/fake-target.sh:targets/vllm-serve.sh:qwen3-coder-2080ti/run-*.sh",
               "LLMCTL_SUPERVISOR": self.supervisor, "LLMCTL_ENVS_DIR": str(self.home / "envs"),
               "LLMCTL_BASE": "base", "LLMCTL_MODEL_DIRS": str(self.home / "models"), "HF_HOME": str(self.home / "hf")}
        self.proc = subprocess.Popen([sys.executable, "-m", "llmctl"], cwd=CONTROL, env=env,
                                     stdout=open(self.home / "panel.out", "ab"), stderr=subprocess.STDOUT)
        self.token = None
        for _ in range(100):
            try:
                httpx.get(self.url("/healthz"), timeout=1)
                break
            except httpx.HTTPError:
                time.sleep(0.1)
        self.token = yaml.safe_load((self.home / "config.yaml").read_text())["token"]
        return self

    def down(self):
        if self.proc:
            self.proc.terminate()
            self.proc.wait(10)
            self.proc = None

    def url(self, path):
        return f"http://127.0.0.1:{self.port}{path}"

    def api(self, method, path, **kw):
        r = httpx.request(method, self.url(path), headers={"Authorization": f"Bearer {self.token}"}, timeout=90, **kw)
        return r

    def inst(self, name):
        for i in self.api("GET", "/api/state").json()["instances"]:
            if i["name"] == name:
                return i
        raise KeyError(name)

    def wait(self, name, state, timeout=30):
        deadline = time.time() + timeout
        while time.time() < deadline:
            i = self.inst(name)
            if i["state"] == state:
                return i
            time.sleep(0.3)
        raise AssertionError(f"{name} never reached {state}: {self.inst(name)}")


def alive(pid):
    try:
        os.kill(pid, 0)
        return Path(f"/proc/{pid}/stat").read_text().split()[2] != "Z"
    except (ProcessLookupError, FileNotFoundError):
        return False


@pytest.fixture(params=SUPERVISORS)
def panel(request, tmp_path):
    p = Panel(tmp_path, request.param).up()
    created = []
    p.created = created
    yield p
    for name in created:
        try:
            p.api("POST", f"/api/instances/{name}/stop")
        except httpx.HTTPError:
            pass
    p.down()
    if request.param == "systemd":
        for name in created:
            subprocess.run(["systemctl", "--user", "stop", f"llmctl-{name}.service"], capture_output=True)
            subprocess.run(["systemctl", "--user", "reset-failed", f"llmctl-{name}.service"], capture_output=True)


def make(panel, env, name=None):
    name = name or f"t-{uuid.uuid4().hex[:6]}"
    panel.created.append(name)
    data = {"script": "control/tests/fake-target.sh", "description": "test", "env": env}
    r = panel.api("PUT", f"/api/instances/{name}", json={"data": data, "create": True})
    assert r.status_code == 200, r.text
    return name


def test_lifecycle_gateway_and_cleanup(panel):
    port = free_port()
    name = make(panel, {"PORT": str(port), "SERVED_MODEL_NAME": "m-one", "FAKE_LOAD_SECONDS": "2"})
    assert panel.inst(name)["state"] == "stopped"
    assert panel.inst(name)["port"] == port and panel.inst(name)["gpus"] == ["0"]
    r = panel.api("POST", f"/api/instances/{name}/start")
    assert r.status_code == 200, r.text
    assert panel.wait(name, "starting", 5)["state"] == "starting"
    ready = panel.wait(name, "ready", 30)
    assert ready["served"] == ["m-one"]
    pids = ready["pids"]
    assert len(pids) >= 2, ready  # engine + its worker carry LLMCTL_INSTANCE

    models = httpx.get(panel.url("/v1/models")).json()["data"]
    assert [m["id"] for m in models] == ["m-one"]
    body = {"model": "m-one", "messages": [{"role": "user", "content": "hello there"}]}
    r = httpx.post(panel.url("/v1/chat/completions"), json=body, timeout=30)
    assert r.status_code == 200 and r.json()["choices"][0]["message"]["content"] == "echo: hello there"
    with httpx.stream("POST", panel.url("/v1/chat/completions"), json={**body, "stream": True}, timeout=30) as s:
        text = "".join(s.iter_text())
    assert text.count("data: ") >= 4 and text.rstrip().endswith("[DONE]")
    r = httpx.post(panel.url("/v1/chat/completions"), json={**body, "model": "nope"})
    assert r.status_code == 404 and "m-one" in r.text

    t = panel.api("POST", "/api/chat-test", json={"model": "m-one", "prompt": "hi"}).json()
    assert t["content"] == "echo: hi" and t["instance"] == name

    logs = panel.api("GET", f"/api/instances/{name}/logs").json()["text"]
    assert "fake engine m-one" in logs

    r = panel.api("POST", f"/api/instances/{name}/stop")
    assert r.status_code == 200 and r.json()["state"] == "stopped"
    time.sleep(0.5)
    assert not any(alive(p) for p in pids), "a process survived the stop"
    assert httpx.get(panel.url("/v1/models")).json()["data"] == []


def test_failures_are_shown(panel):
    bad = make(panel, {"PORT": str(free_port()), "FAIL_PREFLIGHT": "7"})
    panel.api("POST", f"/api/instances/{bad}/start")
    failed = panel.wait(bad, "failed", 15)
    assert failed["code"] == 7 and "preflight failed on purpose" in failed["error_tail"]

    crash = make(panel, {"PORT": str(free_port()), "SERVED_MODEL_NAME": "crashy", "FAKE_CRASH_AFTER": "3"})
    panel.api("POST", f"/api/instances/{crash}/start")
    panel.wait(crash, "ready", 15)
    gone = panel.wait(crash, "failed", 20)
    assert gone["code"] == 3 and "simulated crash" in gone["error_tail"]
    # a failed instance starts again cleanly
    assert panel.api("POST", f"/api/instances/{crash}/start").status_code == 200
    panel.wait(crash, "ready", 15)


def test_conflicts_drift_and_panel_restart(panel):
    port = free_port()
    a = make(panel, {"PORT": str(port), "SERVED_MODEL_NAME": "a", "CUDA_VISIBLE_DEVICES": "0,1"})
    b = make(panel, {"PORT": str(port), "SERVED_MODEL_NAME": "b"})
    c = make(panel, {"PORT": str(free_port()), "SERVED_MODEL_NAME": "c", "CUDA_VISIBLE_DEVICES": "1"})
    panel.api("POST", f"/api/instances/{a}/start")
    panel.wait(a, "ready", 15)
    r = panel.api("POST", f"/api/instances/{b}/start")
    assert r.status_code == 400 and "포트" in r.json()["detail"]
    r = panel.api("POST", f"/api/instances/{c}/start")
    assert r.status_code == 400 and "GPU 1" in r.json()["detail"]
    assert panel.api("POST", f"/api/instances/{c}/start?force=true").status_code == 200
    panel.wait(c, "ready", 15)

    # editing a running instance marks it as needing a restart
    raw = panel.api("GET", f"/api/instances/{a}").json()["data"]
    raw["env"]["MAX_EXTRA"] = "1"
    assert panel.api("PUT", f"/api/instances/{a}", json={"data": raw}).status_code == 200
    assert panel.inst(a)["drift"] is True
    assert len(panel.api("GET", f"/api/instances/{a}").json()["versions"]) == 1

    # the panel goes away and comes back; the instances keep running and are found again
    pid_before = panel.inst(a)["pids"]
    panel.down()
    time.sleep(1)
    assert all(alive(p) for p in pid_before)
    panel.up()
    assert panel.wait(a, "ready", 15)["pids"] == pid_before
    assert panel.inst(a)["drift"] is True
    assert panel.api("POST", f"/api/instances/{a}/restart").status_code == 200
    assert panel.wait(a, "ready", 15)["drift"] is False


def test_validation_and_auth(panel):
    assert httpx.get(panel.url("/api/state")).status_code == 401
    r = panel.api("PUT", "/api/instances/x1", json={"data": {"script": "../../etc/passwd.sh", "env": {}}})
    assert r.status_code == 400
    r = panel.api("PUT", "/api/instances/Bad Name", json={"data": {"script": "control/tests/fake-target.sh"}})
    assert r.status_code == 400
    r = panel.api("PUT", "/api/instances/x2", json={"data": {"script": "control/tests/fake-target.sh",
                                                               "env": {"PID_FILE": "/tmp/x"}}})
    assert r.status_code == 400
    s = {x["path"]: x for x in panel.api("GET", "/api/scripts").json()}
    assert {"control/tests/fake-target.sh", "targets/vllm-serve.sh", "qwen3-coder-2080ti/run-llama-server.sh"} <= set(s)
    knobs = {k["var"]: k for k in s["control/tests/fake-target.sh"]["knobs"]}
    assert knobs["PORT"]["default"] == "18000" and knobs["PORT"]["comment"] == "API port."
    assert "PID_FILE" not in knobs


def hf_model(home, repo_id, arch, quant=None):
    snap = home / "hf" / "hub" / ("models--" + repo_id.replace("/", "--")) / "snapshots" / "abc"
    snap.mkdir(parents=True)
    cfg = {"architectures": [arch], "model_type": arch.lower(), "torch_dtype": "bfloat16",
           "max_position_embeddings": 262144}
    if quant:
        cfg["quantization_config"] = {"quant_method": quant}
    (snap / "config.json").write_text(json.dumps(cfg))


def test_variants_of_the_base_model(panel):
    home = panel.home
    hf_model(home, "Qwen/Qwen3.8-27B-FP8", "Qwen3_8ForCausalLM", "fp8")
    hf_model(home, "someone/Qwen3.8-27B-Coder-AWQ", "Qwen3_8ForCausalLM", "awq")
    hf_model(home, "meta-llama/Llama-3.3-70B-Instruct", "LlamaForCausalLM")
    (home / "models" / "q").mkdir(parents=True)
    (home / "models" / "q" / "Qwen3.8-27B-Q4_K_M.gguf").write_bytes(b"0" * 10)
    base_port = free_port()
    make(panel, {"PORT": str(base_port), "SERVED_MODEL_NAME": "qwen3.8-27b-fp8", "MAX_MODEL_LEN": "65536"}, name="base")

    r = panel.api("GET", "/api/models").json()
    fam = {m["id"]: m["family"] for m in r["models"]}
    assert fam == {"Qwen/Qwen3.8-27B-FP8": "base-model", "someone/Qwen3.8-27B-Coder-AWQ": "variant",
                   "meta-llama/Llama-3.3-70B-Instruct": "other", "q/Qwen3.8-27B-Q4_K_M.gguf": "gguf"}
    assert r["models"][0]["instances"] == ["base"]
    assert next(m for m in r["models"] if m["family"] == "variant")["quant"] == "awq"

    # a variant copies the base instance's script and settings and changes only model, name and port
    v = panel.api("POST", "/api/models/instance", json={"value": "someone/Qwen3.8-27B-Coder-AWQ",
                                                         "id": "someone/Qwen3.8-27B-Coder-AWQ", "family": "variant"})
    assert v.status_code == 200, v.text
    v = v.json()
    panel.created.append(v["name"])
    assert v["script"] == "control/tests/fake-target.sh" and v["env"]["MAX_MODEL_LEN"] == "65536"
    assert v["env"]["MODEL"] == "someone/Qwen3.8-27B-Coder-AWQ" and v["served_name"] == "qwen3.8-27b-coder-awq"
    assert v["port"] != base_port

    o = panel.api("POST", "/api/models/instance", json={"value": "meta-llama/Llama-3.3-70B-Instruct",
                                                         "id": "meta-llama/Llama-3.3-70B-Instruct", "family": "other"}).json()
    panel.created.append(o["name"])
    assert o["script"] == "targets/vllm-serve.sh" and o["env"]["MODEL"] == "meta-llama/Llama-3.3-70B-Instruct"
    g = panel.api("POST", "/api/models/instance", json={"value": str(home / "models/q/Qwen3.8-27B-Q4_K_M.gguf"),
                                                         "id": "q/Qwen3.8-27B-Q4_K_M.gguf", "family": "gguf"}).json()
    panel.created.append(g["name"])
    assert g["script"] == "qwen3-coder-2080ti/run-llama-server.sh"
    assert g["env"]["MODEL_PATH"].endswith(".gguf") and "LLAMA_PORT" in g["env"]

    # base and variant run side by side; the gateway routes by name and an empty model goes to the base
    panel.api("POST", "/api/instances/base/start")
    panel.api("POST", f"/api/instances/{v['name']}/start?force=true")
    panel.wait("base", "ready", 15)
    panel.wait(v["name"], "ready", 15)
    msg = [{"role": "user", "content": "x"}]
    r = httpx.post(panel.url("/v1/chat/completions"), json={"model": "qwen3.8-27b-coder-awq", "messages": msg}, timeout=20)
    assert r.status_code == 200
    r = httpx.post(panel.url("/v1/chat/completions"), json={"model": "default", "messages": msg}, timeout=20)
    assert r.status_code == 200
    ids = [m["id"] for m in httpx.get(panel.url("/v1/models")).json()["data"]]
    assert {"qwen3.8-27b-fp8", "qwen3.8-27b-coder-awq", "default"} <= set(ids)
    assert panel.api("GET", "/api/state").json()["instances"][0]["name"] == "base"

    # two instances with the same serving name cannot run at once
    dup = make(panel, {"PORT": str(free_port()), "SERVED_MODEL_NAME": "qwen3.8-27b-fp8", "CUDA_VISIBLE_DEVICES": "5"})
    r = panel.api("POST", f"/api/instances/{dup}/start")
    assert r.status_code == 400 and "서빙 이름" in r.json()["detail"]
