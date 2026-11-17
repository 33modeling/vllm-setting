"""Instance lifecycle and the 2-second monitor loop that turns unit state + /v1/models into a display state."""
import asyncio
import json
import os
import time
from pathlib import Path

import httpx

from . import instances as I
from . import probe, scripts as S, supervisor as SV
from .settings import REPO

BASE_ENV = ("PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "SHELL")
UNRESPONSIVE_AFTER = 3  # failed checks in a row after being ready


class Manager:
    def __init__(self, cfg):
        self.cfg = cfg
        self.sup = SV.make(cfg)
        self.store = I.Store(cfg)
        self.client = httpx.AsyncClient()
        self.live = {}  # name -> runtime info
        self.gpu = []
        self.orphans = []
        self.busy = {}  # name -> "starting"/"stopping" while a call is in flight
        self.reload()

    # ---- definitions -------------------------------------------------------------------------------------------
    def reload(self):
        self.scripts = S.discover(self.cfg.scripts)
        self.instances, self.errors = self.store.load_all(self.scripts)

    def _state_file(self, name):
        return self.cfg.state_dir / f"{name}.run.json"

    def _run_record(self, name):
        try:
            return json.loads(self._state_file(name).read_text())
        except (OSError, ValueError):
            return {}

    def log_path(self, name):
        return self.cfg.logs_dir / f"{name}.log"

    def describe(self, name):
        inst = self.instances[name]
        script = self.scripts[inst.script]
        eff = I.effective(inst, script)
        rec = self._run_record(name)
        rt = self.live.get(name, {})
        state = self.busy.get(name) or rt.get("state", "stopped")
        drift = bool(rec.get("hash")) and rt.get("running") and rec.get("hash") != I.spec_hash(inst, inst.script)
        return {**inst.as_dict(), **eff, "title": script.title, "state": state, "code": rt.get("code"),
                "since": rt.get("since"), "ready_since": rt.get("ready_since"), "served": rt.get("served"),
                "error_tail": rt.get("error_tail"), "drift": drift, "started_at": rec.get("started"),
                "gpu_mem": rt.get("gpu_mem", 0), "pids": rt.get("pids", [])}

    # ---- actions -----------------------------------------------------------------------------------------------
    def conflicts(self, name, own_port_free=True):
        inst = self.instances[name]
        eff = I.effective(inst, self.scripts[inst.script])
        problems = []
        if eff["port"] is None:
            problems.append(("error", "포트 값을 숫자로 정해야 합니다"))
        for other, oi in self.instances.items():
            if other == name or not self.live.get(other, {}).get("running"):
                continue
            oe = I.effective(oi, self.scripts[oi.script])
            if oe["port"] == eff["port"]:
                problems.append(("error", f"포트 {eff['port']}를 '{other}'가 쓰고 있습니다"))
            shared = set(oe["gpus"]) & set(eff["gpus"])
            if shared:
                problems.append(("warn", f"GPU {','.join(sorted(shared))}를 '{other}'도 쓰고 있습니다"))
        if own_port_free and eff["port"] and not any(p[0] == "error" for p in problems) \
                and probe.port_in_use(eff["port"]):
            problems.append(("error", f"포트 {eff['port']}를 관리판 밖의 프로세스가 쓰고 있습니다"))
        return problems

    async def start(self, name, force=False):
        if name not in self.instances:
            raise KeyError(name)
        if self.live.get(name, {}).get("running") or name in self.busy:
            raise ValueError("이미 실행 중입니다")
        problems = self.conflicts(name)
        blocking = [m for level, m in problems if level == "error" or (level == "warn" and not force)]
        if blocking:
            raise ValueError(" / ".join(blocking))
        inst = self.instances[name]
        script = self.scripts[inst.script]
        env = {k: os.environ[k] for k in (*BASE_ENV, *self.cfg.pass_env) if os.environ.get(k)}
        env.update({k: os.path.expanduser(v) if v.startswith("~") else v for k, v in inst.env.items()})
        env[script.var_for("PID_FILE")] = str(self.cfg.state_dir / f"{name}.pid")
        env["LLMCTL_INSTANCE"] = name
        env["PYTHONUNBUFFERED"] = "1"
        log = self.log_path(name)
        with open(log, "a") as f:
            f.write(f"\n===== llmctl: start {name} ({inst.script}) {time.strftime('%Y-%m-%d %H:%M:%S')} =====\n")
        self._state_file(name).write_text(json.dumps({"started": time.time(), "hash": I.spec_hash(inst, inst.script),
                                                      "log_offset": log.stat().st_size}))
        self.busy[name] = "starting"
        try:
            await asyncio.to_thread(self.sup.start, name, ["/usr/bin/env", "bash", str(REPO / inst.script)], env,
                                    REPO, log)
        finally:
            self.busy.pop(name, None)
        self.live[name] = {"running": True, "state": "starting", "since": time.time(), "fails": 0}

    async def stop(self, name):
        self.busy[name] = "stopping"
        try:
            await asyncio.to_thread(self.sup.stop, name)
            await asyncio.to_thread(self.sup.forget, name)
        finally:
            self.busy.pop(name, None)
        self.live[name] = {"running": False, "state": "stopped"}
        with open(self.log_path(name), "a") as f:
            f.write(f"===== llmctl: stopped {time.strftime('%Y-%m-%d %H:%M:%S')} =====\n")

    async def restart(self, name, force=False):
        # It was already running alongside the others, so only hard conflicts (ports) stop a restart, and they are
        # checked before stopping so a refused restart never leaves the instance down.
        errors = [m for level, m in self.conflicts(name, own_port_free=False) if level == "error"]
        if errors:
            raise ValueError(" / ".join(errors))
        await self.stop(name)
        await self.start(name, force=True)

    async def autostart(self):
        await self.refresh()
        for name, inst in self.instances.items():
            if inst.autostart and not self.live.get(name, {}).get("running"):
                try:
                    await self.start(name)
                except (ValueError, RuntimeError) as exc:
                    self.live[name] = {"running": False, "state": "failed", "error_tail": f"자동 시작 실패: {exc}"}

    # ---- monitoring --------------------------------------------------------------------------------------------
    def tail(self, name, lines=40, since_start=True):
        p = self.log_path(name)
        if not p.exists():
            return ""
        offset = self._run_record(name).get("log_offset", 0) if since_start else 0
        with p.open("rb") as f:
            size = f.seek(0, 2)
            start = max(offset, size - 65536)
            f.seek(start)
            text = f.read().decode(errors="replace")
        return "\n".join(text.splitlines()[-lines:])

    async def refresh(self):
        pid_map = await asyncio.to_thread(SV.instance_pids)
        self.gpu = await asyncio.to_thread(probe.gpus)
        mem = {}
        orphans = []
        for g in self.gpu:
            for p in g["procs"]:
                owner = pid_map.get(p["pid"])
                p["instance"] = owner
                if owner:
                    mem[owner] = mem.get(owner, 0) + (p["mem"] or 0)
                else:
                    orphans.append({**p, "gpu": g["index"], "cmd": _cmdline(p["pid"])})
        self.orphans = orphans
        for name, inst in self.instances.items():
            st = await asyncio.to_thread(self.sup.status, name)
            rt = self.live.setdefault(name, {"running": False, "state": "stopped"})
            rt["gpu_mem"] = mem.get(name, 0)
            rt["pids"] = sorted(pid for pid, owner in pid_map.items() if owner == name)
            if st["phase"] == "stopping":
                rt.update(running=True, state="stopping")
                continue
            if not st["running"]:
                if st["phase"] == "exited":
                    if rt.get("state") != "failed" or rt.get("code") != st["code"]:
                        rt.update(running=False, state="failed" if st["code"] else "stopped", code=st["code"],
                                  error_tail=self.tail(name, 30))
                else:
                    if rt.get("state") != "failed":
                        rt.update(running=False, state="stopped", code=None)
                continue
            if not rt.get("running"):
                rec = self._run_record(name)
                rt.update(running=True, state="starting", since=rec.get("started", time.time()), fails=0,
                          error_tail=None, code=None)
            eff = I.effective(inst, self.scripts[inst.script])
            served = await probe.models(self.client, eff["host"], eff["port"]) if eff["port"] else None
            if served is not None:
                if rt["state"] != "ready":
                    rt["ready_since"] = time.time()
                rt.update(state="ready", served=served, fails=0)
            else:
                rt["fails"] = rt.get("fails", 0) + 1
                if rt["state"] in ("ready", "unresponsive") and rt["fails"] >= UNRESPONSIVE_AFTER:
                    rt["state"] = "unresponsive"
                elif rt["state"] not in ("ready", "unresponsive"):
                    rt["state"] = "starting"

    async def loop(self):
        while True:
            try:
                self.reload()
                await self.refresh()
            except Exception as exc:  # keep monitoring whatever one round hits
                print(f"[llmctl] monitor round failed: {exc!r}", flush=True)
            await asyncio.sleep(self.cfg.poll_seconds)

    # ---- gateway routing ---------------------------------------------------------------------------------------
    def route(self, model):
        model = self.cfg.aliases.get(model, model)
        for name, inst in self.instances.items():
            rt = self.live.get(name, {})
            if rt.get("state") != "ready":
                continue
            eff = I.effective(inst, self.scripts[inst.script])
            if model in (rt.get("served") or []) or model == eff["served_name"] or model == name:
                return name, eff, model
        return None, None, model

    def ready_models(self):
        out = []
        for name, inst in self.instances.items():
            rt = self.live.get(name, {})
            if rt.get("state") == "ready":
                for m in rt.get("served") or [I.effective(inst, self.scripts[inst.script])["served_name"]]:
                    out.append({"id": m, "object": "model", "owned_by": f"llmctl:{name}"})
        for alias, target in self.cfg.aliases.items():
            if any(m["id"] == target for m in out):
                out.append({"id": alias, "object": "model", "owned_by": f"llmctl:alias->{target}"})
        return out


def _cmdline(pid):
    try:
        return Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace").strip()[:300]
    except OSError:
        return ""
