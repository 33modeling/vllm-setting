"""GPU readings from nvidia-smi and the engines' /v1/models check."""
import shutil
import subprocess

import httpx

GPU_FIELDS = ["index", "uuid", "name", "utilization.gpu", "memory.used", "memory.total", "temperature.gpu",
              "power.draw", "power.limit"]


def _num(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def gpus():
    """List of GPUs with their compute processes; [] when there is no NVIDIA driver."""
    if not shutil.which("nvidia-smi"):
        return []
    try:
        r = subprocess.run(["nvidia-smi", f"--query-gpu={','.join(GPU_FIELDS)}", "--format=csv,noheader,nounits"],
                           capture_output=True, text=True, timeout=10)
        apps = subprocess.run(["nvidia-smi", "--query-compute-apps=gpu_uuid,pid,used_memory,process_name",
                               "--format=csv,noheader,nounits"], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return []
    out = []
    for line in r.stdout.strip().splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < len(GPU_FIELDS):
            continue
        g = dict(zip(GPU_FIELDS, parts))
        out.append({"index": int(g["index"]), "uuid": g["uuid"], "name": g["name"],
                    "util": _num(g["utilization.gpu"]), "mem_used": _num(g["memory.used"]),
                    "mem_total": _num(g["memory.total"]), "temp": _num(g["temperature.gpu"]),
                    "power": _num(g["power.draw"]), "power_limit": _num(g["power.limit"]), "procs": []})
    by_uuid = {g["uuid"]: g for g in out}
    for line in apps.stdout.strip().splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) >= 3 and parts[0] in by_uuid and parts[1].isdigit():
            by_uuid[parts[0]]["procs"].append({"pid": int(parts[1]), "mem": _num(parts[2]),
                                               "name": parts[3] if len(parts) > 3 else ""})
    return out


def engine_host(host):
    return "127.0.0.1" if host in ("", "0.0.0.0", "::", "localhost") else host


async def models(client, host, port):
    """Served model ids, or None if the engine does not answer yet."""
    try:
        r = await client.get(f"http://{engine_host(host)}:{port}/v1/models", timeout=3)
    except httpx.HTTPError:
        return None
    if r.status_code != 200:
        return None
    try:
        return [m.get("id") for m in r.json().get("data", [])]
    except (ValueError, AttributeError):
        return []


def port_in_use(port):
    import socket
    for family, addr in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET, "0.0.0.0")):
        s = socket.socket(family, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind((addr, port))
        except OSError:
            return True
        finally:
            s.close()
    return False
