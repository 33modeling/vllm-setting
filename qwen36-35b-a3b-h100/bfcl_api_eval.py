"""BFCL simple/multiple/parallel 을 vLLM OpenAI API 로 평가 (표준 라이브러리만 사용).

서버에 tools 를 전달해 tool_calls 응답을 받고, possible_answer 와 이름/파라미터를
대조하는 간이 AST 채점을 수행한다. agent-benchmarks/local_eval/run_eval.py 의
채점기와 동일 로직 (리더보드 공식 checker 의 단순화 구현이므로 ±수 %p 오차 가능).

사용:
  python3 bfcl_api_eval.py --base-url http://localhost:8000/v1 --model qwen3.6-35b-a3b
  python3 bfcl_api_eval.py --limit 10   # 스모크
"""

import argparse
import ast
import concurrent.futures as cf
import json
import pathlib
import re
import sys
import time
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
DATA = HERE / "data"
OUT = HERE / "results"
CATEGORIES = ["simple", "multiple", "parallel"]

DATA_ROOT = "https://huggingface.co/datasets/gorilla-llm/Berkeley-Function-Calling-Leaderboard/resolve/main"

SYSTEM = (
    "You are a function-calling assistant. Use the provided tools to answer. "
    "Respond with tool calls only."
)


# ---------- 데이터 다운로드 ----------

def ensure_data() -> None:
    DATA.mkdir(exist_ok=True)
    for cat in CATEGORIES:
        for kind, rel in [("question", f"BFCL_v3_{cat}.json"),
                          ("answer", f"possible_answer/BFCL_v3_{cat}.json")]:
            out = DATA / f"{cat}_{kind}.jsonl"
            if out.exists() and out.stat().st_size > 0:
                continue
            url = f"{DATA_ROOT}/{rel}"
            print(f"downloading {rel} ...", flush=True)
            with urllib.request.urlopen(url, timeout=60) as r:
                out.write_bytes(r.read())


def load_jsonl(path: pathlib.Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


# ---------- 채점기 (local_eval/run_eval.py 와 동일) ----------

def norm_name(name: str) -> str:
    return name.replace(".", "_").strip()


def norm_value(v):
    if isinstance(v, str):
        s = v.strip().strip("'\"")
        try:
            return norm_value(ast.literal_eval(s))
        except Exception:
            return s.lower()
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float)):
        return round(float(v), 6)
    if isinstance(v, list):
        return tuple(norm_value(x) for x in v)
    if isinstance(v, dict):
        return tuple(sorted((k, norm_value(x)) for k, x in v.items()))
    return v


def value_allowed(got, allowed: list) -> bool:
    g = norm_value(got)
    return any(norm_value(c) == g for c in allowed)


def match_one(call: dict, answer: dict) -> bool:
    (fname, params), = answer.items()
    if norm_name(call["name"]) != norm_name(fname):
        return False
    args = call["arguments"]
    if not isinstance(args, dict):
        return False
    for p, allowed in params.items():
        optional = "" in allowed
        if p not in args or args[p] in (None, ""):
            if optional:
                continue
            return False
        if not value_allowed(args[p], [a for a in allowed if a != ""]):
            return False
    return all(p in params for p in args)


def score_sample(calls: list[dict], answers: list[dict]) -> bool:
    if len(calls) != len(answers):
        return False
    used = set()
    for answer in answers:
        hit = next((i for i, c in enumerate(calls)
                    if i not in used and match_one(c, answer)), None)
        if hit is None:
            return False
        used.add(hit)
    return True


# ---------- API 클라이언트 ----------

TOOL_CALL_RE = re.compile(r"<tool_call>\s*(\{.*?\})\s*</tool_call>", re.DOTALL)


def chat(base_url: str, model: str, messages: list, tools: list,
         timeout: int = 300) -> list[dict]:
    body = json.dumps({
        "model": model, "messages": messages, "tools": tools,
        "temperature": 0.0, "max_tokens": 1024,
    }).encode()
    req = urllib.request.Request(
        f"{base_url}/chat/completions", data=body,
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        resp = json.load(r)
    msg = resp["choices"][0]["message"]
    calls = []
    for tc in msg.get("tool_calls") or []:
        fn = tc.get("function", {})
        try:
            args = json.loads(fn.get("arguments") or "{}")
        except json.JSONDecodeError:
            args = {}
        calls.append({"name": fn.get("name", ""), "arguments": args})
    if not calls and msg.get("content"):
        for m in TOOL_CALL_RE.finditer(msg["content"]):
            try:
                obj = json.loads(m.group(1))
                calls.append({"name": str(obj.get("name", "")),
                              "arguments": obj.get("arguments") or {}})
            except json.JSONDecodeError:
                pass
    return calls


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", default="http://localhost:8000/v1")
    ap.add_argument("--model", default="qwen3.6-35b-a3b")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--workers", type=int, default=8)
    args = ap.parse_args()

    ensure_data()
    OUT.mkdir(exist_ok=True)

    report = {"model": args.model, "base_url": args.base_url, "categories": {}}
    failures = []

    for cat in CATEGORIES:
        questions = load_jsonl(DATA / f"{cat}_question.jsonl")
        answers = {r["id"]: r for r in load_jsonl(DATA / f"{cat}_answer.jsonl")}
        if args.limit:
            questions = questions[: args.limit]

        def run_one(q):
            user_turns = q["question"][0] if isinstance(q["question"][0], list) else q["question"]
            messages = [{"role": "system", "content": SYSTEM}] + user_turns
            tools = [{"type": "function", "function": f} for f in q["function"]]
            try:
                calls = chat(args.base_url, args.model, messages, tools)
            except Exception as e:
                return q["id"], [], f"API error: {e}"
            return q["id"], calls, None

        n_ok, t0 = 0, time.time()
        with cf.ThreadPoolExecutor(max_workers=args.workers) as ex:
            for i, (qid, calls, err) in enumerate(ex.map(run_one, questions)):
                gt = answers[qid]["ground_truth"]
                ok = err is None and score_sample(calls, gt)
                n_ok += ok
                if not ok and len(failures) < 30:
                    failures.append({"id": qid, "category": cat, "error": err,
                                     "generated": calls, "expected": gt})
                if (i + 1) % 50 == 0:
                    print(f"[{cat}] {i+1}/{len(questions)} acc={n_ok/(i+1):.3f} "
                          f"({(time.time()-t0)/(i+1):.2f}s/sample)", flush=True)
        acc = n_ok / max(len(questions), 1)
        report["categories"][cat] = {"n": len(questions), "correct": n_ok,
                                     "accuracy": round(acc, 4)}
        print(f"== {cat}: {n_ok}/{len(questions)} = {acc:.4f}", flush=True)

    total_n = sum(c["n"] for c in report["categories"].values())
    total_ok = sum(c["correct"] for c in report["categories"].values())
    report["overall"] = {"n": total_n, "correct": total_ok,
                         "accuracy": round(total_ok / max(total_n, 1), 4)}

    (OUT / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False))
    (OUT / "failures.json").write_text(json.dumps(failures, indent=2, ensure_ascii=False))
    lines = [f"# BFCL 평가 — {args.model} (vLLM API)", "",
             "| 카테고리 | 문제 수 | 정답 | 정확도 |", "|---|---:|---:|---:|"]
    for cat, c in report["categories"].items():
        lines.append(f"| {cat} | {c['n']} | {c['correct']} | {c['accuracy']:.1%} |")
    o = report["overall"]
    lines.append(f"| **전체** | {o['n']} | {o['correct']} | **{o['accuracy']:.1%}** |")
    (OUT / "report.md").write_text("\n".join(lines) + "\n")
    print(json.dumps(report["overall"], ensure_ascii=False))


if __name__ == "__main__":
    sys.exit(main())
