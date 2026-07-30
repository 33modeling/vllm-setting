"""bfcl_api_eval.py 하니스 자체 검증 (GPU·vLLM 불필요).

1) 채점기 자체 테스트: possible_answer 로부터 '정답 호출'을 만들어 넣으면 100%,
   값을 틀리면 오답 처리되는지 확인.
2) E2E 테스트: 모의 OpenAI 서버(정답을 tool_calls 로 돌려줌)를 띄우고
   bfcl_api_eval.py 를 실제 HTTP 로 돌려 정확도 100% 가 나오는지 확인.

사용: python3 test_harness.py
"""

import json
import pathlib
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import bfcl_api_eval as ev  # noqa: E402

PORT = 8765


def gt_to_calls(ground_truth: list[dict]) -> list[dict]:
    calls = []
    for answer in ground_truth:
        (fname, params), = answer.items()
        args = {}
        for p, allowed in params.items():
            vals = [a for a in allowed if a != ""]
            if not vals:
                continue  # 순수 옵션 파라미터는 생략
            args[p] = vals[0]
        calls.append({"name": fname, "arguments": args})
    return calls


def test_scorer() -> None:
    ev.ensure_data()
    for cat in ev.CATEGORIES:
        answers = ev.load_jsonl(ev.DATA / f"{cat}_answer.jsonl")
        n = 0
        for row in answers[:50]:
            gt = row["ground_truth"]
            calls = gt_to_calls(gt)
            assert ev.score_sample(calls, gt), f"정답 재현 실패: {cat} {row['id']}"
            # 값 하나를 틀리게 바꾸면 오답이어야 함
            if calls and calls[0]["arguments"]:
                bad = json.loads(json.dumps(calls))
                k = next(iter(bad[0]["arguments"]))
                bad[0]["arguments"][k] = "___wrong___"
                assert not ev.score_sample(bad, gt), f"오답 미검출: {cat} {row['id']}"
            n += 1
        print(f"[scorer] {cat}: {n}건 정답재현+오답검출 OK")


class MockHandler(BaseHTTPRequestHandler):
    """유저 질문 텍스트 → ground_truth 를 tool_calls 로 돌려주는 모의 vLLM."""

    gt_by_question: dict[str, list[dict]] = {}

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"data": []}')

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        user_text = next(m["content"] for m in body["messages"]
                         if m["role"] == "user")
        calls = gt_to_calls(self.gt_by_question.get(user_text, []))
        msg = {"role": "assistant", "content": None, "tool_calls": [
            {"id": f"call_{i}", "type": "function",
             "function": {"name": c["name"],
                          "arguments": json.dumps(c["arguments"])}}
            for i, c in enumerate(calls)]}
        resp = {"choices": [{"message": msg}]}
        data = json.dumps(resp).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):  # 테스트 출력 소음 제거
        pass


def test_e2e() -> None:
    for cat in ev.CATEGORIES:
        questions = ev.load_jsonl(ev.DATA / f"{cat}_question.jsonl")
        answers = {r["id"]: r["ground_truth"]
                   for r in ev.load_jsonl(ev.DATA / f"{cat}_answer.jsonl")}
        for q in questions:
            turns = q["question"][0] if isinstance(q["question"][0], list) else q["question"]
            user_text = next(m["content"] for m in turns if m["role"] == "user")
            MockHandler.gt_by_question[user_text] = answers[q["id"]]

    server = ThreadingHTTPServer(("127.0.0.1", 0), MockHandler)
    port = server.server_address[1]
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    try:
        proc = subprocess.run(
            [sys.executable, str(HERE / "bfcl_api_eval.py"),
             "--base-url", f"http://127.0.0.1:{port}/v1",
             "--model", "mock", "--limit", "5", "--workers", "4"],
            capture_output=True, text=True, timeout=120)
        print(proc.stdout.strip().splitlines()[-1] if proc.stdout else proc.stderr[-500:])
        assert proc.returncode == 0, proc.stderr[-1000:]
        report = json.loads((HERE / "results" / "report.json").read_text())
        acc = report["overall"]["accuracy"]
        assert acc == 1.0, f"모의 서버 E2E 정확도 {acc} != 1.0 — failures.json 확인"
        print(f"[e2e] 모의 서버 15문제 정확도 {acc:.0%} OK")
    finally:
        server.shutdown()


if __name__ == "__main__":
    test_scorer()
    test_e2e()
    print("ALL TESTS PASSED")
