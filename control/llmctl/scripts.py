"""Target scripts: discovery and the knobs they read.

A knob is a line `NAME="${VAR:-default}"` (optionally `export`). VAR is what the caller sets; NAME tells its role
(PORT, SERVED_MODEL_NAME, PID_FILE, HOST, CUDA_VISIBLE_DEVICES). The `#` lines right above become its description.
"""
import re
from dataclasses import dataclass, field
from pathlib import Path

from .settings import REPO

KNOB = re.compile(r'^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)="\$\{([A-Z_][A-Z0-9_]*):-(.*)\}"\s*(?:#.*)?$')
ROLES = ("PORT", "SERVED_MODEL_NAME", "PID_FILE", "HOST", "CUDA_VISIBLE_DEVICES", "MODEL", "MODEL_PATH", "TP_SIZE")


@dataclass
class Knob:
    var: str
    role: str
    default: str
    comment: str


@dataclass
class Script:
    path: str  # relative to the repository
    title: str
    knobs: list = field(default_factory=list)

    def knob(self, role):
        for k in self.knobs:
            if k.role == role:
                return k
        return None

    def var_for(self, role):
        k = self.knob(role)
        return k.var if k else role

    def as_dict(self):
        return {"path": self.path, "title": self.title,
                "knobs": [k.__dict__ for k in self.knobs if k.role not in ("PID_FILE", "ENV_FILE")]}


def parse(path):
    lines = Path(path).read_text(errors="replace").splitlines()
    title, knobs, comment, seen = "", [], [], set()
    for i, line in enumerate(lines):
        s = line.strip()
        if s.startswith("#!"):
            continue
        if s.startswith("#"):
            text = s.lstrip("#").strip()
            comment.append(text)
            if not title and text and not knobs and i < 15:
                title = text
            continue
        m = KNOB.match(line)
        if m:
            role, var, default = m.groups()
            if var not in seen:
                seen.add(var)
                knobs.append(Knob(var=var, role=role, default=default,
                                  comment=" ".join(c for c in comment if c).strip()))
        comment = [] if not s.startswith("#") else comment
    return Script(path=str(Path(path).resolve().relative_to(REPO)), title=title, knobs=knobs)


def discover(globs):
    found = {}
    for pattern in globs:
        for p in sorted(REPO.glob(pattern)):
            if p.is_file() and p.suffix == ".sh":
                try:
                    s = parse(p)
                except (OSError, ValueError):
                    continue
                if s.knob("PORT"):  # only scripts that start a server
                    found[s.path] = s
    return found
