"""A stand-in for vLLM/SGLang: OpenAI-compatible /v1/models and /v1/chat/completions (stream and not).

FAKE_LOAD_SECONDS delays readiness like a model load, FAKE_CRASH_AFTER exits with code 3 after that many seconds,
and it starts a child "worker" process (like vLLM's engine core) so tests can check nothing survives a stop.
"""
import json
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port = int(sys.argv[1])
name = sys.argv[2]
load = float(os.environ.get("FAKE_LOAD_SECONDS", "0"))
crash = float(os.environ.get("FAKE_CRASH_AFTER", "0"))
started = time.time()
worker = subprocess.Popen([sys.executable, "-c", "import time\nwhile True: time.sleep(1)"])
print(f"fake engine {name} on {port}, worker pid {worker.pid}", flush=True)


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if time.time() - started < load:
            return self._json(503, {"error": "loading"})
        if self.path == "/v1/models":
            return self._json(200, {"object": "list", "data": [{"id": name, "object": "model"}]})
        self._json(404, {"error": "not found"})

    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        if req.get("model") != name:
            return self._json(404, {"error": f"model {req.get('model')} not served"})
        text = "echo: " + req["messages"][-1]["content"]
        if req.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            for word in text.split(" "):
                chunk = {"choices": [{"delta": {"content": word + " "}, "index": 0}]}
                self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
                self.wfile.flush()
                time.sleep(0.05)
            self.wfile.write(b"data: [DONE]\n\n")
            return
        self._json(200, {"choices": [{"message": {"role": "assistant", "content": text}, "index": 0}],
                         "usage": {"prompt_tokens": 3, "completion_tokens": len(text.split()), "total_tokens": 9}})


def crasher():
    time.sleep(crash)
    print("fake engine: simulated crash", flush=True)
    worker.kill()
    os._exit(3)


if crash:
    threading.Thread(target=crasher, daemon=True).start()
try:
    ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
finally:
    worker.kill()
