"""Models already on this server: the HuggingFace cache and the folders in config `model_dirs`.

For each model it reads config.json (architecture, quantization, dtype, context) so the panel can tell variants of
the base model (same architecture: fine-tunes, AWQ/GPTQ/FP8 builds) from other families, and GGUF files, which go to
llama.cpp. Nothing is downloaded or changed here.
"""
import json
import os
import re
import time
from pathlib import Path

_cache = {"at": 0, "key": None, "items": []}


def hf_hub():
    if os.environ.get("HF_HUB_CACHE"):
        return Path(os.environ["HF_HUB_CACHE"])
    return Path(os.environ.get("HF_HOME", "~/.cache/huggingface")).expanduser() / "hub"


def _size(path):
    total = 0
    for root, _dirs, files in os.walk(path):
        for f in files:
            try:
                total += os.stat(os.path.join(root, f)).st_size  # follows HF snapshot symlinks to the blobs
            except OSError:
                pass
    return total


def read_config(folder):
    try:
        cfg = json.loads((Path(folder) / "config.json").read_text())
    except (OSError, ValueError):
        return None
    text = cfg.get("text_config") or {}
    quant = cfg.get("quantization_config") or text.get("quantization_config") or {}
    method = quant.get("quant_method") or quant.get("format") or ""
    if not method and re.search(r"(fp8|awq|gptq|int4|int8)", str(folder).lower()):
        method = re.search(r"(fp8|awq|gptq|int4|int8)", str(folder).lower()).group(1)
    return {
        "architectures": cfg.get("architectures") or [],
        "model_type": cfg.get("model_type") or text.get("model_type") or "",
        "quant": method,
        "dtype": cfg.get("torch_dtype") or text.get("torch_dtype") or "",
        "context": cfg.get("max_position_embeddings") or text.get("max_position_embeddings"),
    }


def scan(model_dirs, ttl=60):
    key = (str(hf_hub()), tuple(str(d) for d in model_dirs))
    if _cache["key"] == key and time.time() - _cache["at"] < ttl:
        return _cache["items"]
    items = []
    hub = hf_hub()
    if hub.is_dir():
        for d in sorted(hub.glob("models--*")):
            snaps = sorted((d / "snapshots").glob("*"), key=lambda p: p.stat().st_mtime, reverse=True) \
                if (d / "snapshots").is_dir() else []
            if not snaps:
                continue
            repo_id = d.name[len("models--"):].replace("--", "/", 1)
            info = read_config(snaps[0])
            ggufs = sorted(snaps[0].glob("*.gguf"))
            if info:
                items.append({"id": repo_id, "value": repo_id, "where": "HuggingFace 캐시", "kind": "hf",
                              "size": _size(d / "blobs"), **info})
            for g in ggufs:
                items.append(_gguf(g, f"{repo_id}/{g.name}", "HuggingFace 캐시"))
    for base in model_dirs:
        base = Path(str(base)).expanduser()
        if not base.is_dir():
            continue
        for d in sorted(p for p in base.iterdir() if p.is_dir()):
            info = read_config(d)
            if info:
                items.append({"id": d.name, "value": str(d), "where": str(base), "kind": "hf", "size": _size(d),
                              **info})
            for g in sorted(d.glob("*.gguf")):
                items.append(_gguf(g, f"{d.name}/{g.name}", str(base)))
        for g in sorted(base.glob("*.gguf")):
            items.append(_gguf(g, g.name, str(base)))
    # split GGUF parts (-00001-of-00003) are one model; keep the first part only
    items = [i for i in items if not (i["kind"] == "gguf" and re.search(r"-0000[2-9]-of-|-000[1-9][0-9]-of-", i["id"]))]
    _cache.update(at=time.time(), key=key, items=items)
    return items


def _gguf(path, ident, where):
    try:
        size = path.stat().st_size
    except OSError:
        size = 0
    m = re.search(r"(I?Q\d[_A-Z0-9]*|F16|BF16|F32)", path.name, re.I)
    return {"id": ident, "value": str(path.resolve()), "where": where, "kind": "gguf", "size": size,
            "architectures": [], "model_type": "gguf", "quant": m.group(1).upper() if m else "gguf", "dtype": "",
            "context": None}


def served_name(model_id):
    name = Path(str(model_id).rstrip("/")).name
    name = re.sub(r"\.gguf$", "", name, flags=re.I)
    return re.sub(r"[^a-z0-9._-]+", "-", name.lower()).strip("-") or "model"
