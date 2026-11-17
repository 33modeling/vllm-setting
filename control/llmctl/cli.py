"""Terminal client for the panel API: llmctl status | start NAME | stop NAME | restart NAME | logs NAME [-f]."""
import sys
import time

import httpx

from . import settings

STATE_KO = {"stopped": "꺼짐", "starting": "켜는 중", "ready": "준비됨", "unresponsive": "응답 없음",
            "failed": "실패", "stopping": "끄는 중"}


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    cfg = settings.load(create=False)
    base = f"http://127.0.0.1:{cfg.port}"
    h = {"Authorization": f"Bearer {cfg.token}"}
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return 0
    cmd, rest = argv[0], argv[1:]
    try:
        if cmd == "status":
            s = httpx.get(base + "/api/state", headers=h, timeout=10).json()
            for g in s["gpus"]:
                print(f"GPU{g['index']} {g['name']}: {g['util']:.0f}%  {g['mem_used']:.0f}/{g['mem_total']:.0f} MiB"
                      f"  {g['temp']:.0f}°C")
            for i in s["instances"]:
                extra = f" (종료 코드 {i['code']})" if i["state"] == "failed" else ""
                drift = "  * 설정 바뀜, 재시작 필요" if i["drift"] else ""
                print(f"{i['name']:24} {STATE_KO.get(i['state'], i['state']):6}{extra}  :{i['port']}"
                      f"  {i['served_name'] or '-'}  GPU {','.join(i['gpus']) or '-'}{drift}")
            for o in s["orphans"]:
                print(f"관리 밖 GPU 프로세스: pid {o['pid']} GPU{o['gpu']} {o['mem']:.0f} MiB  {o['cmd'][:80]}")
            return 0
        if cmd in ("start", "stop", "restart") and rest:
            force = "--force" in rest
            name = [r for r in rest if not r.startswith("--")][0]
            r = httpx.post(f"{base}/api/instances/{name}/{cmd}", headers=h, params={"force": force}, timeout=200)
            if r.status_code != 200:
                print(r.json().get("detail", r.text), file=sys.stderr)
                return 1
            print(f"{name}: {STATE_KO.get(r.json()['state'], r.json()['state'])}")
            return 0
        if cmd == "logs" and rest:
            name, follow = rest[0], "-f" in rest
            r = httpx.get(f"{base}/api/instances/{name}/logs", headers=h, params={"limit": 20000}, timeout=10).json()
            sys.stdout.write(r["text"])
            while follow:
                time.sleep(1)
                r = httpx.get(f"{base}/api/instances/{name}/logs", headers=h, params={"offset": r["offset"]},
                              timeout=10).json()
                sys.stdout.write(r["text"])
                sys.stdout.flush()
            return 0
    except httpx.HTTPError as exc:
        print(f"관리판({base})에 연결하지 못했습니다: {exc}. systemctl --user status llmctl 로 확인하세요.",
              file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
