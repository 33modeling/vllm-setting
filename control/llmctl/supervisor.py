"""Start and stop instance processes outside the panel's own process tree.

SystemdSupervisor: one transient user unit per instance (`llmctl-<name>.service`). Stopping it stops the whole
cgroup, so engine worker processes cannot outlive it. LocalSupervisor: a new session/process group per instance with
a pid record, for machines without a systemd user session. Both survive a restart of the panel.
"""
import json
import os
import shutil
import signal
import subprocess
import time
from pathlib import Path

UNIT_PREFIX = "llmctl-"


def unit(name):
    return f"{UNIT_PREFIX}{name}.service"


class Status(dict):
    """running: bool, phase: running|stopping|exited|stopped, code: int|None, pid, since"""


def _run(cmd, timeout=30):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


class SystemdSupervisor:
    kind = "systemd"

    def __init__(self, cfg):
        self.cfg = cfg

    @staticmethod
    def available():
        if not shutil.which("systemd-run") or not shutil.which("systemctl"):
            return False
        try:
            return _run(["systemctl", "--user", "is-system-running"], 10).stdout.strip() not in ("", "offline")
        except (OSError, subprocess.SubprocessError):
            return False

    def start(self, name, argv, env, cwd, log):
        _run(["systemctl", "--user", "reset-failed", unit(name)])
        cmd = ["systemd-run", "--user", "--quiet", "--unit", unit(name), "--description", f"llmctl instance {name}",
               "--working-directory", str(cwd),
               "-p", f"StandardOutput=append:{log}", "-p", f"StandardError=append:{log}",
               "-p", "KillMode=control-group", "-p", "KillSignal=SIGTERM",
               "-p", f"TimeoutStopSec={self.cfg.stop_timeout}", "-p", "SendSIGKILL=yes"]
        cmd += [f"--setenv={k}={v}" for k, v in env.items()]
        cmd += ["--", *argv]
        r = _run(cmd)
        if r.returncode:
            raise RuntimeError(r.stderr.strip() or "systemd-run failed")

    def stop(self, name):
        _run(["systemctl", "--user", "stop", unit(name)], self.cfg.stop_timeout + 30)

    def status(self, name):
        r = _run(["systemctl", "--user", "show", unit(name), "-p",
                  "LoadState,ActiveState,SubState,MainPID,ExecMainStatus,ExecMainCode,ActiveEnterTimestampMonotonic,"
                  "InactiveEnterTimestampMonotonic"])
        p = dict(line.split("=", 1) for line in r.stdout.splitlines() if "=" in line)
        active = p.get("ActiveState", "inactive")
        pid = int(p.get("MainPID") or 0)
        code = p.get("ExecMainStatus")
        code = int(code) if code and code.isdigit() else None
        if p.get("LoadState") == "not-found" or active == "inactive":
            return Status(running=False, phase="stopped", code=None, pid=None)
        if active in ("active", "activating", "reloading"):
            return Status(running=True, phase="running", code=None, pid=pid or None)
        if active == "deactivating":
            return Status(running=True, phase="stopping", code=None, pid=pid or None)
        return Status(running=False, phase="exited", code=code, pid=None)

    def forget(self, name):
        _run(["systemctl", "--user", "reset-failed", unit(name)])

    def list_running(self):
        r = _run(["systemctl", "--user", "list-units", "--all", "--plain", "--no-legend", f"{UNIT_PREFIX}*"])
        return [line.split()[0][len(UNIT_PREFIX):-len(".service")] for line in r.stdout.splitlines()
                if line.split() and line.split()[0].endswith(".service")]


class LocalSupervisor:
    kind = "local"

    def __init__(self, cfg):
        self.cfg = cfg
        self.children = {}

    def _record(self, name):
        return self.cfg.state_dir / f"{name}.proc.json"

    def start(self, name, argv, env, cwd, log):
        full = {**{k: v for k, v in os.environ.items() if k in ("PATH", "HOME", "USER", "LANG")}, **env}
        out = open(log, "ab")
        proc = subprocess.Popen(argv, cwd=cwd, env=full, stdout=out, stderr=subprocess.STDOUT,
                                stdin=subprocess.DEVNULL, start_new_session=True)
        out.close()
        self.children[name] = proc
        self._record(name).write_text(json.dumps({"pid": proc.pid, "started": time.time()}))

    def _pid(self, name):
        try:
            return json.loads(self._record(name).read_text())["pid"]
        except (OSError, ValueError, KeyError):
            return None

    @staticmethod
    def _alive(pid, name):
        try:
            env = Path(f"/proc/{pid}/environ").read_bytes().split(b"\0")
        except OSError:
            return False
        return f"LLMCTL_INSTANCE={name}".encode() in env

    def status(self, name):
        proc = self.children.get(name)
        if proc is not None:
            code = proc.poll()
            if code is None:
                return Status(running=True, phase="running", code=None, pid=proc.pid)
            return Status(running=False, phase="exited", code=code if code >= 0 else 128 - code, pid=None)
        pid = self._pid(name)
        if pid and self._alive(pid, name):
            return Status(running=True, phase="running", code=None, pid=pid)
        return Status(running=False, phase="stopped", code=None, pid=None)

    def stop(self, name):
        pid = self._pid(name)
        proc = self.children.get(name)
        if not pid or not self._alive(pid, name):
            self._record(name).unlink(missing_ok=True)
            return
        try:
            os.killpg(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        deadline = time.time() + self.cfg.stop_timeout
        while time.time() < deadline and _group_alive(pid):
            if proc is not None:
                proc.poll()
            time.sleep(0.3)
        if _group_alive(pid):
            try:
                os.killpg(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if proc is not None:
            proc.wait(timeout=10)
        self._record(name).unlink(missing_ok=True)

    def forget(self, name):
        self.children.pop(name, None)
        self._record(name).unlink(missing_ok=True)

    def list_running(self):
        return [p.name[:-len(".proc.json")] for p in self.cfg.state_dir.glob("*.proc.json")]


def _group_alive(pgid):
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def make(cfg):
    if cfg.supervisor == "systemd" or (cfg.supervisor == "auto" and SystemdSupervisor.available()):
        return SystemdSupervisor(cfg)
    return LocalSupervisor(cfg)


def instance_pids():
    """pid -> instance name for every process started by the panel (both supervisors set LLMCTL_INSTANCE)."""
    out = {}
    for d in Path("/proc").iterdir():
        if not d.name.isdigit():
            continue
        try:
            env = (d / "environ").read_bytes()
        except OSError:
            continue
        i = env.find(b"LLMCTL_INSTANCE=")
        if i >= 0:
            out[int(d.name)] = env[i + 16:].split(b"\0", 1)[0].decode(errors="replace")
    return out
