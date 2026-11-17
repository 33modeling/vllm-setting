"""Paths and control/config.yaml.

LLMCTL_HOME holds everything machine-local (config.yaml, instances/, logs/, state/). It defaults to control/ so a
plain checkout works; tests point it at a temporary directory.
"""
import os
import secrets
from dataclasses import dataclass, field
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[2]  # the vllm-setting checkout
CONTROL = REPO / "control"
WEB = CONTROL / "web"

DEFAULT_SCRIPTS = ["targets/*.sh", "qwen3-coder-2080ti/run-*.sh"]


@dataclass
class Config:
    home: Path
    listen: str = "0.0.0.0"
    port: int = 8700
    token: str = ""
    gateway_key: str = ""
    aliases: dict = field(default_factory=dict)
    scripts: list = field(default_factory=lambda: list(DEFAULT_SCRIPTS))
    envs_dir: Path = Path("~/.local/share/llm-envs").expanduser()
    supervisor: str = "auto"  # auto | systemd | local
    pass_env: list = field(default_factory=lambda: ["HF_HOME", "HF_TOKEN", "HUGGING_FACE_HUB_TOKEN", "CUDA_HOME",
                                                    "LD_LIBRARY_PATH", "VLLM_CACHE_ROOT", "TRANSFORMERS_CACHE"])
    stop_timeout: int = 60
    poll_seconds: float = 2.0

    @property
    def instances_dir(self):
        return self.home / "instances"

    @property
    def logs_dir(self):
        return self.home / "logs"

    @property
    def state_dir(self):
        return self.home / "state"

    @property
    def path(self):
        return self.home / "config.yaml"


def load(home=None, create=True):
    home = Path(home or os.environ.get("LLMCTL_HOME") or CONTROL).expanduser().resolve()
    cfg = Config(home=home)
    data = {}
    if cfg.path.exists():
        data = yaml.safe_load(cfg.path.read_text()) or {}
    for key in ("listen", "port", "token", "gateway_key", "aliases", "scripts", "supervisor", "pass_env",
                "stop_timeout", "poll_seconds"):
        if key in data and data[key] is not None:
            setattr(cfg, key, data[key])
    if data.get("envs_dir"):
        cfg.envs_dir = Path(str(data["envs_dir"])).expanduser()
    if os.environ.get("LLMCTL_SCRIPTS"):
        cfg.scripts = os.environ["LLMCTL_SCRIPTS"].split(":")
    if os.environ.get("LLMCTL_ENVS_DIR"):
        cfg.envs_dir = Path(os.environ["LLMCTL_ENVS_DIR"]).expanduser()
    if os.environ.get("LLMCTL_SUPERVISOR"):
        cfg.supervisor = os.environ["LLMCTL_SUPERVISOR"]
    if os.environ.get("LLMCTL_PORT"):
        cfg.port = int(os.environ["LLMCTL_PORT"])
    for d in (cfg.instances_dir, cfg.logs_dir, cfg.state_dir):
        d.mkdir(parents=True, exist_ok=True)
    if create and not cfg.token:
        cfg.token = secrets.token_urlsafe(24)
        data["token"] = cfg.token
        for key, value in (("listen", cfg.listen), ("port", cfg.port)):
            data.setdefault(key, value)
        data.setdefault("aliases", {})
        cfg.path.write_text("# llmctl settings (machine-local, not in git). See docs/control.md.\n"
                            + yaml.safe_dump(data, allow_unicode=True, sort_keys=False))
        cfg.path.chmod(0o600)
    return cfg
