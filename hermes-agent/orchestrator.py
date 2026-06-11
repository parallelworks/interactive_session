#!/usr/bin/env python3
"""Hermes ORCHESTRATOR -- an OpenAI-compatible agent that coordinates per-cluster workers.

Declared in the workflow as an `openAI: true` session, so the Activate platform
registers it as a chat model and wires it into the built-in chat UI. You just
chat with it -- no bespoke UI. It discovers worker agents (`pw sessions ls`), and
the GLM brain decides when to delegate tasks to them (tools: list_workers,
delegate) and synthesizes the reply.

OpenAI-compatible endpoints (suffix-matched, so the session path prefix is fine):
  GET  /v1/models            advertise this orchestrator as a model
  POST /v1/chat/completions  agent loop; supports stream=true (SSE)
Debug: GET / or /health (status), GET /workers (discovered workers).
"""
import argparse
import base64
import json
import os
import subprocess
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL_ID = os.environ.get("HERMES_MODEL_ID", "hermes-orchestrator")  # name shown in chat
DEFAULT_PORT = os.environ.get("HERMES_AGENT_PORT", "8717")
DISPATCH_TIMEOUT = int(os.environ.get("HERMES_DISPATCH_TIMEOUT", "1800"))
LOCAL_TEST = os.environ.get("HERMES_LOCAL_TEST") == "1"
WORKER_MARKER = os.environ.get("HERMES_WORKER_SESSION", "hermes_worker")
# Brain (platform OpenAI-compatible endpoint) for the orchestrator's own reasoning.
BRAIN = os.environ.get("OPENAI_BASE_URL", "").rstrip("/")
API_KEY = os.environ.get("OPENAI_API_KEY", "")          # = PW_API_KEY at runtime
ALLOCATION = os.environ.get("X_ALLOCATION", "")
BRAIN_MODEL = os.environ.get("MODEL", "org:glm/glm-5.1")

SYSTEM = (
    "You are the Hermes orchestrator. You coordinate worker agents, each running on a "
    "different compute cluster. Use list_workers to see which clusters are available, and "
    "delegate(cluster, task) to have a cluster's agent run commands there and report back. "
    "To answer questions about the clusters, delegate to the relevant workers -- you may "
    "call delegate several times in one turn, once per cluster -- then synthesize their "
    "replies into one clear answer. Only delegate to clusters returned by list_workers."
)
TOOLS = [
    {"type": "function", "function": {
        "name": "list_workers",
        "description": "List the available worker agents (one per cluster).",
        "parameters": {"type": "object", "properties": {}}}},
    {"type": "function", "function": {
        "name": "delegate",
        "description": "Run a task on a specific cluster's worker agent; returns its result.",
        "parameters": {"type": "object", "properties": {
            "cluster": {"type": "string", "description": "cluster name from list_workers"},
            "task": {"type": "string", "description": "what the worker should do"}},
            "required": ["cluster", "task"]}}},
]


def discover_workers():
    try:
        out = subprocess.run(["pw", "sessions", "ls", "-o", "json"],
                             capture_output=True, text=True, timeout=30)
        data = json.loads(out.stdout or "[]")
    except Exception:
        return []
    rows = data if isinstance(data, list) else data.get("sessions", data.get("data", []))
    seen, workers = set(), []
    for s in rows:
        name = s.get("name") or ""
        if WORKER_MARKER not in name or s.get("status") != "running":
            continue
        cluster = (s.get("targetName") or "").split("/")[-1]
        if not cluster or cluster in seen:
            continue
        seen.add(cluster)
        workers.append({"cluster": cluster,
                        "port": s.get("remotePort") or int(DEFAULT_PORT), "session": name})
    return workers


def delegate(cluster, task, port):
    payload = json.dumps({"task": task})
    b64 = base64.b64encode(payload.encode()).decode()
    remote = ("echo {b} | base64 -d | curl -s -m {to} -X POST "
              "-H 'Content-Type: application/json' --data-binary @- "
              "http://localhost:{port}/task").format(b=b64, to=DISPATCH_TIMEOUT, port=port)
    argv = ["bash", "-c", remote] if LOCAL_TEST else ["pw", "ssh", cluster, remote]
    try:
        out = subprocess.run(argv, capture_output=True, text=True, timeout=DISPATCH_TIMEOUT + 60)
        body = (out.stdout or "").strip()
        try:
            body = json.loads(body)
        except Exception:
            pass
        return {"cluster": cluster, "ok": out.returncode == 0, "result": body}
    except Exception as e:  # noqa: BLE001
        return {"cluster": cluster, "ok": False, "error": str(e)}


def brain(messages, tools=None):
    body = {"model": BRAIN_MODEL, "messages": messages}
    if tools:
        body["tools"], body["tool_choice"] = tools, "auto"
    headers = {"Authorization": "Bearer " + API_KEY, "Content-Type": "application/json"}
    if ALLOCATION:
        headers["X-Allocation"] = ALLOCATION
    req = urllib.request.Request(BRAIN + "/chat/completions",
                                 data=json.dumps(body).encode(), headers=headers)
    with urllib.request.urlopen(req, timeout=DISPATCH_TIMEOUT) as r:
        return json.load(r)["choices"][0]["message"]


def agent(messages, max_steps=6):
    """Agent loop: brain decides to list_workers / delegate (tools), we execute, repeat."""
    msgs = [{"role": "system", "content": SYSTEM}] + messages
    for _ in range(max_steps):
        m = brain(msgs, TOOLS)
        msgs.append({k: v for k, v in m.items() if v is not None})
        calls = m.get("tool_calls") or []
        if not calls:
            return m.get("content", "")
        cache = {w["cluster"]: w for w in discover_workers()}

        def run_call(tc):
            fn = tc["function"]["name"]
            args = json.loads(tc["function"].get("arguments") or "{}")
            if fn == "list_workers":
                out = discover_workers()
            elif fn == "delegate":
                c = args.get("cluster", "")
                port = cache.get(c, {}).get("port", int(DEFAULT_PORT))
                r = delegate(c, args.get("task", ""), port)
                out = r.get("result", r)
            else:
                out = {"error": "unknown tool " + fn}
            return {"role": "tool", "tool_call_id": tc["id"], "content": json.dumps(out)}

        with ThreadPoolExecutor(max_workers=min(16, len(calls))) as ex:
            for res in ex.map(run_call, calls):
                msgs.append(res)
    return "(reached step limit without a final answer)"


class Handler(BaseHTTPRequestHandler):
    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        p = self.path.rstrip("/")
        if p.endswith("/models"):
            self._json(200, {"object": "list", "data": [
                {"id": MODEL_ID, "object": "model", "created": int(time.time()), "owned_by": "hermes"}]})
        elif p.endswith("/workers"):
            self._json(200, {"workers": discover_workers()})
        else:
            self._json(200, {"status": "ok", "role": "orchestrator", "model": MODEL_ID})

    def do_POST(self):
        if not self.path.rstrip("/").endswith("chat/completions"):
            self._json(404, {"error": "not found"})
            return
        try:
            n = int(self.headers.get("Content-Length", 0))
            req = json.loads(self.rfile.read(n) or b"{}")
            messages = req.get("messages", [])
            content = agent(messages)
            if req.get("stream"):
                self._stream(content)
            else:
                self._json(200, {
                    "id": "chatcmpl-hermes", "object": "chat.completion",
                    "created": int(time.time()), "model": MODEL_ID,
                    "choices": [{"index": 0, "finish_reason": "stop",
                                 "message": {"role": "assistant", "content": content}}]})
        except Exception as e:  # noqa: BLE001
            self._json(500, {"error": {"message": str(e), "type": "orchestrator_error"}})

    def _stream(self, content):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        def chunk(delta, finish=None):
            obj = {"id": "chatcmpl-hermes", "object": "chat.completion.chunk",
                   "created": int(time.time()), "model": MODEL_ID,
                   "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
            self.wfile.write(("data: " + json.dumps(obj) + "\n\n").encode())

        chunk({"role": "assistant", "content": content})
        chunk({}, "stop")
        self.wfile.write(b"data: [DONE]\n\n")

    def log_message(self, *a):
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=int(os.environ.get("service_port", "8717")))
    ap.add_argument("--host", default="0.0.0.0")
    args = ap.parse_args()
    print("hermes orchestrator (OpenAI-compatible) on {}:{} as model '{}'".format(
        args.host, args.port, MODEL_ID), flush=True)
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
