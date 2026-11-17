"""Engine environments (one uv environment per engine and version) and the jobs that install them."""
import asyncio
import re
import subprocess
import time
import uuid
from pathlib import Path

from .settings import REPO

INSTALLER = REPO / "envs" / "install-engine.sh"
ENGINES = {"vllm": "vllm", "sglang": "sglang"}
VERSION = re.compile(r"^[0-9][0-9A-Za-z.+-]{0,40}$|^latest$")
_cache = {}


def _version(python, package):
    key = (str(python), package, python.stat().st_mtime if python.exists() else 0)
    if key not in _cache:
        try:
            r = subprocess.run([str(python), "-c", f"import importlib.metadata as m; print(m.version('{package}'))"],
                               capture_output=True, text=True, timeout=30)
            _cache[key] = r.stdout.strip() or None
        except (OSError, subprocess.SubprocessError):
            _cache[key] = None
    return _cache[key]


def listing(envs_dir):
    out = []
    root = Path(envs_dir)
    if not root.is_dir():
        return out
    for d in sorted(root.iterdir()):
        python = d / "bin" / "python"
        if not python.exists():
            continue
        item = {"name": d.name, "path": str(d), "engines": {}, "lock": (d / "lock.txt").exists()}
        for engine, package in ENGINES.items():
            version = _version(python, package)
            if version:
                item["engines"][engine] = version
        item["bins"] = {"VLLM_BIN": str(d / "bin" / "vllm")} if (d / "bin" / "vllm").exists() else {}
        if "sglang" in item["engines"]:
            item["bins"]["SGLANG_PYTHON"] = str(python)
        out.append(item)
    return out


class Jobs:
    """Background installs, one at a time, with a log file each."""

    def __init__(self, cfg):
        self.cfg = cfg
        self.jobs = {}
        self.lock = asyncio.Lock()

    def get(self, jid):
        return self.jobs.get(jid)

    def all(self):
        return sorted(self.jobs.values(), key=lambda j: j["started"], reverse=True)

    async def install(self, engine, version):
        if engine not in ENGINES:
            raise ValueError("엔진은 vllm 또는 sglang 입니다")
        if not VERSION.match(version or ""):
            raise ValueError("버전은 0.17.1 같은 형식이나 latest 여야 합니다")
        if any(j["state"] == "running" for j in self.jobs.values()):
            raise ValueError("다른 설치가 진행 중입니다")
        jid = uuid.uuid4().hex[:8]
        log = self.cfg.logs_dir / f"job-{jid}.log"
        job = {"id": jid, "title": f"{engine} {version} 설치", "state": "running", "started": time.time(),
               "ended": None, "code": None, "log": str(log)}
        self.jobs[jid] = job
        asyncio.create_task(self._run(job, [str(INSTALLER), engine, version], log))
        return job

    async def _run(self, job, argv, log):
        env = {"LLM_ENVS": str(self.cfg.envs_dir)}
        import os
        with open(log, "ab") as out:
            proc = await asyncio.create_subprocess_exec(*argv, stdout=out, stderr=asyncio.subprocess.STDOUT,
                                                        stdin=asyncio.subprocess.DEVNULL,
                                                        env={**os.environ, **env})
            code = await proc.wait()
        job.update(state="done" if code == 0 else "failed", code=code, ended=time.time())
