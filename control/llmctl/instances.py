"""Instances: one YAML file = one target script + the values it runs with."""
import hashlib
import re
import time
from dataclasses import dataclass, field
from pathlib import Path

import yaml

from .settings import REPO

NAME = re.compile(r"^[a-z0-9][a-z0-9._-]{0,47}$")
ENV_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
RESERVED_ENV = {"PID_FILE", "LLAMA_PID_FILE", "LLMCTL_INSTANCE"}


class Invalid(ValueError):
    pass


@dataclass
class Instance:
    name: str
    script: str
    env: dict = field(default_factory=dict)
    description: str = ""
    autostart: bool = False

    def to_yaml(self):
        data = {"script": self.script}
        if self.description:
            data["description"] = self.description
        data["env"] = {k: str(v) for k, v in self.env.items()}
        data["autostart"] = bool(self.autostart)
        return yaml.safe_dump(data, allow_unicode=True, sort_keys=False)

    def as_dict(self):
        return {"name": self.name, "script": self.script, "env": dict(self.env), "description": self.description,
                "autostart": self.autostart}


def validate(name, data, scripts):
    if not NAME.match(name or ""):
        raise Invalid("이름은 영어 소문자, 숫자, . _ - 로 48자 이내여야 합니다")
    if not isinstance(data, dict):
        raise Invalid("인스턴스 내용이 올바른 YAML 사전이 아닙니다")
    script = data.get("script")
    if script not in scripts:
        raise Invalid(f"스크립트 '{script}'는 이 저장소의 타깃 스크립트가 아닙니다")
    env = data.get("env") or {}
    if not isinstance(env, dict):
        raise Invalid("env는 이름: 값 목록이어야 합니다")
    clean = {}
    for k, v in env.items():
        if not ENV_NAME.match(str(k)):
            raise Invalid(f"환경 변수 이름 '{k}'가 올바르지 않습니다")
        if k in RESERVED_ENV:
            raise Invalid(f"{k}는 관리판이 정하는 값이라 적을 수 없습니다")
        if v is None or str(v) == "":
            continue
        if "\n" in str(v) or "\0" in str(v):
            raise Invalid(f"{k} 값에 줄바꿈을 넣을 수 없습니다")
        clean[str(k)] = str(v)
    return Instance(name=name, script=script, env=clean, description=str(data.get("description") or ""),
                    autostart=bool(data.get("autostart")))


class Store:
    def __init__(self, cfg):
        self.dir = cfg.instances_dir
        self.history = self.dir / ".history"

    def path(self, name):
        return self.dir / f"{name}.yaml"

    def load_all(self, scripts):
        out, errors = {}, {}
        for p in sorted(self.dir.glob("*.yaml")):
            try:
                out[p.stem] = validate(p.stem, yaml.safe_load(p.read_text()), scripts)
            except (Invalid, yaml.YAMLError, OSError) as exc:
                errors[p.stem] = str(exc)
        return out, errors

    def raw(self, name):
        p = self.path(name)
        return p.read_text() if p.exists() else None

    def _backup(self, name, reason):
        p = self.path(name)
        if p.exists():
            self.history.mkdir(exist_ok=True)
            stamp = time.strftime("%Y%m%d-%H%M%S")
            (self.history / f"{name}.{stamp}.{reason}.yaml").write_text(p.read_text())

    def save(self, inst):
        self._backup(inst.name, "before-save")
        tmp = self.path(inst.name).with_suffix(".tmp")
        tmp.write_text(inst.to_yaml())
        tmp.replace(self.path(inst.name))

    def delete(self, name):
        self._backup(name, "deleted")
        self.path(name).unlink(missing_ok=True)

    def versions(self, name):
        if not self.history.exists():
            return []
        return [{"id": p.name, "time": p.stat().st_mtime}
                for p in sorted(self.history.glob(f"{name}.*.yaml"), reverse=True)]

    def version_text(self, name, vid):
        p = self.history / vid
        if not vid.startswith(name + ".") or p.parent != self.history or not p.exists():
            raise Invalid("없는 이전 판입니다")
        return p.read_text()


def effective(inst, script):
    """Values the script will actually use for the roles the panel needs (instance value, else script default)."""
    def value(role, fallback=""):
        k = script.knob(role)
        if not k:
            return fallback
        return inst.env.get(k.var, k.default)
    port = value("PORT")
    gpus = value("CUDA_VISIBLE_DEVICES", inst.env.get("CUDA_VISIBLE_DEVICES", ""))
    return {
        "port": int(port) if str(port).isdigit() else None,
        "host": value("HOST", "127.0.0.1"),
        "served_name": value("SERVED_MODEL_NAME") or Path(str(value("MODEL") or "")).name,
        "model": value("MODEL") or value("MODEL_PATH"),
        "gpus": [g.strip() for g in str(gpus).split(",") if g.strip()],
    }


def spec_hash(inst, script_path):
    h = hashlib.sha256(inst.to_yaml().encode())
    try:
        h.update(Path(REPO / script_path).read_bytes())
    except OSError:
        pass
    return h.hexdigest()[:16]
