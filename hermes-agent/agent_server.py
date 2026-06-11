#!/usr/bin/env python3
"""Hermes WORKER agent -- an OpenAI-compatible agent for ONE cluster.

Declared in the workflow as an `openAI: true` session, so the Activate platform
registers it as a chat model and wires it into the built-in chat UI. The agent
answers by running shell commands on THIS cluster (brain + run_shell tool).

OpenAI-compatible endpoints (suffix-matched, so the session path prefix is fine):
  GET  /v1/models            advertise this worker as a model
  POST /v1/chat/completions  agent loop; supports stream=true (SSE)
Internal: POST /task  -> {"result": ...}   the orchestrator's delegate contract
Debug:    GET / or /health  -> status

Brain = the platform endpoint (PW_API_KEY + X-Allocation). If a `hermes` binary
is present it is used instead (preferred); with no brain it stubs.
"""
import argparse
import json
import os
import shutil
import subprocess
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CLUSTER = os.environ.get("HERMES_CLUSTER") or os.environ.get("PW_USER") or "unknown"
MODEL_ID = os.environ.get("HERMES_MODEL_ID", "hermes-worker")
TASK_TIMEOUT = int(os.environ.get("HERMES_TASK_TIMEOUT", "1800"))
# Brain config
BASE = os.environ.get("OPENAI_BASE_URL", "").rstrip("/")
API_KEY = os.environ.get("OPENAI_API_KEY", "")          # = PW_API_KEY at runtime
ALLOCATION = os.environ.get("X_ALLOCATION", "")
MODEL = os.environ.get("MODEL", "org:glm/glm-5.1")
HERMES_TASK_CMD = os.environ.get("HERMES_TASK_CMD", "")

SYSTEM = ("You are an agent running on the compute cluster '{}'. Use the run_shell tool to "
          "inspect or act on THIS machine and answer the user from real command output. "
          "Describe only this machine.").format(CLUSTER)
TOOLS = [{
    "type": "function",
    "function": {
        "name": "run_shell",
        "description": "Run a shell command on THIS machine and return its stdout.",
        "parameters": {"type": "object",
                       "properties": {"command": {"type": "string"}},
                       "required": ["command"]}}}]


def run_shell(command):
    out = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=60)
    return (out.stdout or out.stderr).strip()


def _brain(messages):
    body = {"model": MODEL, "messages": messages, "tools": TOOLS, "tool_choice": "auto"}
    headers = {"Authorization": "Bearer " + API_KEY, "Content-Type": "application/json"}
    if ALLOCATION:
        headers["X-Allocation"] = ALLOCATION
    req = urllib.request.Request(BASE + "/chat/completions",
                                 data=json.dumps(body).encode(), headers=headers)
    with urllib.request.urlopen(req, timeout=TASK_TIMEOUT) as r:
        return json.load(r)["choices"][0]["message"]


def _agent(messages, max_steps=4):
    """Run the brain over `messages`, executing run_shell tool calls, until a final reply."""
    msgs = [{"role": "system", "content": SYSTEM}] + messages
    for _ in range(max_steps):
        m = _brain(msgs)
        msgs.append({k: v for k, v in m.items() if v is not None})
        calls = m.get("tool_calls") or []
        if not calls:
            return m.get("content", "")
        for tc in calls:
            args = json.loads(tc["function"].get("arguments") or "{}")
            msgs.append({"role": "tool", "tool_call_id": tc["id"],
                         "content": run_shell(args.get("command", ""))})
    return "(reached step limit)"


def run_hermes_task(task, context=""):
    """Single-shot task (used by /task). Prefers a real hermes; else the brain loop; else stub."""
    prompt = task if not context else "{}\n\n{}".format(context, task)
    if HERMES_TASK_CMD:
        out = subprocess.run(HERMES_TASK_CMD.format(task=prompt), shell=True,
                             capture_output=True, text=True, timeout=TASK_TIMEOUT)
        return (out.stdout or out.stderr).strip()
    if shutil.which("hermes"):
        out = subprocess.run(["hermes", "run", "--prompt", prompt],
                             capture_output=True, text=True, timeout=TASK_TIMEOUT)
        return (out.stdout or out.stderr).strip()
    if BASE and API_KEY:
        return _agent([{"role": "user", "content": prompt}])
    return "[stub:{}] no brain configured: {}".format(CLUSTER, prompt[:200])


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
        else:
            self._json(200, {"status": "ok", "role": "worker", "cluster": CLUSTER,
                             "brain": bool(BASE and API_KEY), "model": MODEL_ID})

    def do_POST(self):
        p = self.path.rstrip("/")
        try:
            n = int(self.headers.get("Content-Length", 0))
            req = json.loads(self.rfile.read(n) or b"{}")
            if p.endswith("chat/completions"):
                content = _agent(req.get("messages", []))
                if req.get("stream"):
                    self._stream(content)
                else:
                    self._json(200, {
                        "id": "chatcmpl-hermes", "object": "chat.completion",
                        "created": int(time.time()), "model": MODEL_ID,
                        "choices": [{"index": 0, "finish_reason": "stop",
                                     "message": {"role": "assistant", "content": content}}]})
            elif p.endswith("/task"):
                self._json(200, {"cluster": CLUSTER,
                                 "result": run_hermes_task(req.get("task", ""), req.get("context", ""))})
            else:
                self._json(404, {"error": "not found"})
        except Exception as e:  # noqa: BLE001
            self._json(500, {"error": {"message": str(e), "type": "worker_error"}})

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
    print("hermes worker [{}] (OpenAI-compatible) on {}:{} | brain={}".format(
        CLUSTER, args.host, args.port, bool(BASE and API_KEY)), flush=True)
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
