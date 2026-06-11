#!/usr/bin/env python3
"""Hermes WORKER agent -- HTTP front-end for a per-cluster agent.

Exposes the agent over one HTTP port so the orchestrator (on the platform
workspace) can reach it via `pw ssh <cluster> curl localhost:<port>`.

Brain = the platform's OpenAI-compatible endpoint. Auth is the runtime
PW_API_KEY (never written to disk); org-provider models also require the
X-Allocation header. The worker runs a minimal real agent loop (a `run_shell`
tool) so it can actually act on the cluster -- e.g. report its own hostname.
If a `hermes` binary is present it is used instead (preferred path).

Endpoints
  GET  /  and  /health   -> {"status":"ok",...}
  POST /task             -> {"result":"..."}   run one task on this cluster
"""
import argparse
import json
import os
import shutil
import subprocess
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROLE = "worker"
CLUSTER = os.environ.get("HERMES_CLUSTER") or os.environ.get("PW_USER") or "unknown"
TASK_TIMEOUT = int(os.environ.get("HERMES_TASK_TIMEOUT", "1800"))

# --- brain config (platform OpenAI-compatible endpoint) -----------------------
BASE = os.environ.get("OPENAI_BASE_URL", "").rstrip("/")
API_KEY = os.environ.get("OPENAI_API_KEY", "")          # = PW_API_KEY at runtime
ALLOCATION = os.environ.get("X_ALLOCATION", "")          # org-provider requirement
MODEL = os.environ.get("MODEL", "org:glm/glm-5.1")
HERMES_TASK_CMD = os.environ.get("HERMES_TASK_CMD", "")  # override for a real hermes

TOOLS = [{
    "type": "function",
    "function": {
        "name": "run_shell",
        "description": "Run a shell command on THIS machine and return its stdout.",
        "parameters": {"type": "object",
                       "properties": {"command": {"type": "string"}},
                       "required": ["command"]},
    },
}]


def _run_shell(command):
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


def _agent_loop(task, context="", max_steps=4):
    """Minimal real agent: let the brain call run_shell, execute, feed back."""
    messages = [
        {"role": "system", "content": "You are an agent running on a compute cluster "
         "named '{}'. When asked about this machine, use run_shell to find out for "
         "real.".format(CLUSTER)},
        {"role": "user", "content": task if not context else context + "\n\n" + task},
    ]
    for _ in range(max_steps):
        msg = _brain(messages)
        messages.append({k: v for k, v in msg.items() if v is not None})
        calls = msg.get("tool_calls") or []
        if not calls:
            return msg.get("content", "")
        for tc in calls:
            args = json.loads(tc["function"].get("arguments") or "{}")
            messages.append({"role": "tool", "tool_call_id": tc["id"],
                             "content": _run_shell(args.get("command", ""))})
    return "(max steps reached)"


def run_hermes_task(task, context=""):
    prompt = task if not context else "{}\n\n{}".format(context, task)
    if HERMES_TASK_CMD:                                  # explicit hermes command
        out = subprocess.run(HERMES_TASK_CMD.format(task=prompt), shell=True,
                             capture_output=True, text=True, timeout=TASK_TIMEOUT)
        return (out.stdout or out.stderr).strip()
    if shutil.which("hermes"):                           # preferred: real hermes
        # TODO confirm headless flag + that hermes can send the X-Allocation header
        out = subprocess.run(["hermes", "run", "--prompt", prompt],
                             capture_output=True, text=True, timeout=TASK_TIMEOUT)
        return (out.stdout or out.stderr).strip()
    if BASE and API_KEY:                                 # built-in minimal agent
        return _agent_loop(task, context)
    return "[stub:{}] no brain configured: {}".format(CLUSTER, prompt[:200])
# ------------------------------------------------------------------------------


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path in ("/", "/health"):
            self._send(200, {"status": "ok", "role": ROLE, "cluster": CLUSTER,
                             "brain": bool(BASE and API_KEY), "model": MODEL})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/task":
            self._send(404, {"error": "not found"})
            return
        try:
            n = int(self.headers.get("Content-Length", 0))
            req = json.loads(self.rfile.read(n) or b"{}")
            result = run_hermes_task(req.get("task", ""), req.get("context", ""))
            self._send(200, {"cluster": CLUSTER, "result": result})
        except Exception as e:  # noqa: BLE001 - surface failures to the caller
            self._send(500, {"cluster": CLUSTER, "error": str(e)})

    def log_message(self, *a):
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=int(os.environ.get("service_port", "8717")))
    ap.add_argument("--host", default="0.0.0.0")
    args = ap.parse_args()
    print("hermes worker [{}] on {}:{} | brain={} model={}".format(
        CLUSTER, args.host, args.port, bool(BASE and API_KEY), MODEL), flush=True)
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
