"""HTTP: the management API under /api (token), the OpenAI-compatible gateway under /v1, and the web page."""
import asyncio
import contextlib
import json
import secrets
import time

import httpx
import yaml
from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, Response, StreamingResponse
from fastapi.staticfiles import StaticFiles

from . import envs, instances as I, probe, settings
from .manager import Manager

HOP = {"connection", "keep-alive", "transfer-encoding", "content-length", "content-encoding", "host"}


def create(cfg=None):
    cfg = cfg or settings.load()
    mgr = Manager(cfg)
    jobs = envs.Jobs(cfg)

    @contextlib.asynccontextmanager
    async def lifespan(app):
        await mgr.autostart()
        task = asyncio.create_task(mgr.loop())
        yield
        task.cancel()
        await mgr.client.aclose()

    app = FastAPI(title="llmctl", lifespan=lifespan, docs_url=None, redoc_url=None)
    app.state.mgr, app.state.cfg = mgr, cfg
    upstream = httpx.AsyncClient(timeout=httpx.Timeout(600, connect=5))

    def auth(request: Request):
        got = request.headers.get("authorization", "").removeprefix("Bearer ").strip()
        if not got or not secrets.compare_digest(got, cfg.token):
            raise HTTPException(401, "토큰이 필요합니다")

    def need(name):
        if name not in mgr.instances:
            raise HTTPException(404, f"인스턴스 '{name}'가 없습니다")

    def fail(exc):
        raise HTTPException(400, str(exc))

    # ---- management API ----------------------------------------------------------------------------------------
    @app.get("/api/state", dependencies=[Depends(auth)])
    async def state():
        return {"instances": [mgr.describe(n) for n in sorted(mgr.instances)], "errors": mgr.errors,
                "gpus": mgr.gpu, "orphans": mgr.orphans, "supervisor": mgr.sup.kind, "time": time.time(),
                "gateway": {"aliases": cfg.aliases, "key_required": bool(cfg.gateway_key), "port": cfg.port}}

    @app.get("/api/scripts", dependencies=[Depends(auth)])
    async def scripts():
        return [s.as_dict() for s in mgr.scripts.values()]

    @app.get("/api/instances/{name}", dependencies=[Depends(auth)])
    async def get_instance(name: str):
        raw = mgr.store.raw(name)
        if raw is None:
            raise HTTPException(404, "없는 인스턴스입니다")
        return {"name": name, "yaml": raw, "data": yaml.safe_load(raw), "versions": mgr.store.versions(name)}

    @app.put("/api/instances/{name}", dependencies=[Depends(auth)])
    async def put_instance(name: str, request: Request):
        body = await request.json()
        try:
            data = yaml.safe_load(body["yaml"]) if "yaml" in body else body.get("data")
            inst = I.validate(name, data, mgr.scripts)
        except (I.Invalid, yaml.YAMLError, KeyError) as exc:
            fail(exc)
        if body.get("create") and mgr.store.raw(name) is not None:
            fail("같은 이름의 인스턴스가 이미 있습니다")
        mgr.store.save(inst)
        mgr.reload()
        return mgr.describe(name)

    @app.post("/api/yaml", dependencies=[Depends(auth)])
    async def parse_yaml(request: Request):
        try:
            data = yaml.safe_load((await request.json()).get("yaml", ""))
        except yaml.YAMLError as exc:
            fail(f"YAML 문법 오류: {exc}")
        if not isinstance(data, dict):
            fail("YAML 최상위는 script, env 같은 항목이어야 합니다")
        return {"data": data}

    @app.delete("/api/instances/{name}", dependencies=[Depends(auth)])
    async def delete_instance(name: str):
        need(name)
        if mgr.live.get(name, {}).get("running"):
            fail("실행 중인 인스턴스는 먼저 꺼야 지울 수 있습니다")
        mgr.store.delete(name)
        mgr.reload()
        return {"deleted": name}

    @app.get("/api/instances/{name}/versions/{vid}", dependencies=[Depends(auth)])
    async def version(name: str, vid: str):
        try:
            return {"yaml": mgr.store.version_text(name, vid)}
        except I.Invalid as exc:
            fail(exc)

    @app.post("/api/instances/{name}/{action}", dependencies=[Depends(auth)])
    async def act(name: str, action: str, force: bool = False):
        need(name)
        try:
            if action == "start":
                await mgr.start(name, force=force)
            elif action == "stop":
                await mgr.stop(name)
            elif action == "restart":
                await mgr.restart(name, force=force)
            else:
                raise HTTPException(404, "없는 동작입니다")
        except (ValueError, RuntimeError) as exc:
            fail(exc)
        return mgr.describe(name)

    @app.get("/api/instances/{name}/check", dependencies=[Depends(auth)])
    async def check(name: str):
        need(name)
        return [{"level": level, "message": m} for level, m in mgr.conflicts(name)]

    @app.get("/api/instances/{name}/logs", dependencies=[Depends(auth)])
    async def logs(name: str, offset: int = -1, limit: int = 200000):
        p = mgr.log_path(name)
        if not p.exists():
            return {"offset": 0, "text": ""}
        with p.open("rb") as f:
            size = f.seek(0, 2)
            start = max(0, size - limit) if offset < 0 or offset > size else offset
            f.seek(start)
            data = f.read(limit)
        return {"offset": start + len(data), "text": data.decode(errors="replace"), "size": size}

    @app.get("/api/envs", dependencies=[Depends(auth)])
    async def env_list():
        return {"dir": str(cfg.envs_dir), "envs": await asyncio.to_thread(envs.listing, cfg.envs_dir),
                "jobs": jobs.all()}

    @app.post("/api/envs/install", dependencies=[Depends(auth)])
    async def env_install(request: Request):
        body = await request.json()
        try:
            return await jobs.install(body.get("engine"), str(body.get("version", "")).strip())
        except ValueError as exc:
            fail(exc)

    @app.get("/api/jobs/{jid}", dependencies=[Depends(auth)])
    async def job(jid: str):
        j = jobs.get(jid)
        if not j:
            raise HTTPException(404, "없는 작업입니다")
        try:
            text = open(j["log"], errors="replace").read()[-100000:]
        except OSError:
            text = ""
        return {**j, "text": text}

    @app.post("/api/chat-test", dependencies=[Depends(auth)])
    async def chat_test(request: Request):
        body = await request.json()
        name, eff, model = mgr.route(body.get("model", ""))
        if not name:
            fail("준비된 인스턴스 가운데 그 모델 이름이 없습니다")
        payload = {"model": model, "messages": [{"role": "user", "content": body.get("prompt") or "안녕하세요"}],
                   "max_tokens": int(body.get("max_tokens") or 256), "stream": False}
        t0 = time.time()
        try:
            r = await upstream.post(f"http://{probe.engine_host(eff['host'])}:{eff['port']}/v1/chat/completions",
                                    json=payload, timeout=300)
        except httpx.HTTPError as exc:
            fail(f"엔진에 연결하지 못했습니다: {exc}")
        took = time.time() - t0
        try:
            data = r.json()
        except ValueError:
            fail(f"엔진 응답이 JSON이 아닙니다 (HTTP {r.status_code})")
        if r.status_code != 200:
            fail(f"엔진이 HTTP {r.status_code}로 답했습니다: {json.dumps(data, ensure_ascii=False)[:500]}")
        msg = (data.get("choices") or [{}])[0].get("message") or {}
        usage = data.get("usage") or {}
        out_tokens = usage.get("completion_tokens")
        return {"instance": name, "model": model, "seconds": round(took, 2), "usage": usage,
                "tokens_per_second": round(out_tokens / took, 1) if out_tokens and took > 0 else None,
                "content": msg.get("content") or "", "reasoning": msg.get("reasoning_content") or msg.get("reasoning")}

    # ---- OpenAI-compatible gateway -----------------------------------------------------------------------------
    def gateway_auth(request: Request):
        if cfg.gateway_key:
            got = request.headers.get("authorization", "").removeprefix("Bearer ").strip()
            if not secrets.compare_digest(got, cfg.gateway_key):
                raise HTTPException(401, "gateway key required")

    @app.get("/v1/models", dependencies=[Depends(gateway_auth)])
    async def gateway_models():
        return {"object": "list", "data": mgr.ready_models()}

    @app.api_route("/v1/{path:path}", methods=["POST", "GET"], dependencies=[Depends(gateway_auth)])
    async def gateway(path: str, request: Request):
        body = await request.body()
        model = ""
        payload = None
        if body:
            try:
                payload = json.loads(body)
                model = payload.get("model", "") if isinstance(payload, dict) else ""
            except ValueError:
                payload = None
        name, eff, real = mgr.route(model or cfg.aliases.get("default", ""))
        if not name:
            ready = [m["id"] for m in mgr.ready_models()]
            return JSONResponse({"error": {"message": f"model '{model}' is not running here; ready: {ready}",
                                           "type": "model_not_found"}}, status_code=404)
        if payload is not None and isinstance(payload, dict) and payload.get("model") != real:
            payload["model"] = real
            body = json.dumps(payload).encode()
        url = f"http://{probe.engine_host(eff['host'])}:{eff['port']}/v1/{path}"
        headers = {k: v for k, v in request.headers.items() if k.lower() not in HOP and k.lower() != "authorization"}
        req = upstream.build_request(request.method, url, content=body, headers=headers,
                                     params=request.query_params)
        try:
            resp = await upstream.send(req, stream=True)
        except httpx.HTTPError as exc:
            return JSONResponse({"error": {"message": f"engine unreachable: {exc}", "type": "upstream_error"}},
                                status_code=502)

        async def relay():
            try:
                async for chunk in resp.aiter_bytes():
                    yield chunk
            finally:
                await resp.aclose()

        out_headers = {k: v for k, v in resp.headers.items() if k.lower() not in HOP}
        return StreamingResponse(relay(), status_code=resp.status_code, headers=out_headers)

    # ---- web page ----------------------------------------------------------------------------------------------
    @app.get("/")
    async def index():
        return FileResponse(settings.WEB / "index.html", headers={"Cache-Control": "no-cache"})

    @app.get("/healthz")
    async def healthz():
        return Response("ok")

    app.mount("/static", StaticFiles(directory=settings.WEB), name="static")
    return app


def main():
    import uvicorn
    cfg = settings.load()
    uvicorn.run(create(cfg), host=cfg.listen, port=cfg.port, log_level="warning")


if __name__ == "__main__":
    main()
