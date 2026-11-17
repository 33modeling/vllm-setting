"""Engine environment listing reads versions from the environments themselves."""
import subprocess
from pathlib import Path

from llmctl import envs


def test_listing_finds_engine_and_bins(tmp_path):
    env = tmp_path / "vllm-9.9.9"
    subprocess.run(["uv", "venv", "-q", "--relocatable", str(env)], check=True)
    site = next(env.glob("lib/python*/site-packages"))
    meta = site / "vllm-9.9.9.dist-info"
    meta.mkdir()
    (meta / "METADATA").write_text("Metadata-Version: 2.1\nName: vllm\nVersion: 9.9.9\n")
    (env / "bin" / "vllm").write_text("#!/bin/sh\n")
    (env / "bin" / "vllm").chmod(0o755)
    (tmp_path / "not-an-env").mkdir()
    got = envs.listing(tmp_path)
    assert [e["name"] for e in got] == ["vllm-9.9.9"]
    assert got[0]["engines"] == {"vllm": "9.9.9"}
    assert got[0]["bins"] == {"VLLM_BIN": str(env / "bin" / "vllm")}
    assert got[0]["lock"] is False
