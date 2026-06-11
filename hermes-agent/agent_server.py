#!/usr/bin/env python3
"""Hermes WORKER agent -- HTTP front-end for a per-cluster Hermes agent.

This is the connective tissue the cross-cluster design needs but Hermes does not
provide on its own: it exposes the locally-installed Hermes agent over a single
HTTP port so the orchestrator (on the platform workspace) can reach it. The
orchestrator talks to this server with `pw ssh <cluster> curl localhost:<port>`,
which reuses the pw client's auth and needs no inbound firewall opening.

Endpoints
  GET  /  and  /health   -> {"status":"ok",...}   readiness probe (session_runner waits on this)
  POST /task             -> {"result":"..."}       run one task on this cluster via Hermes

Stdlib only (http.server) so the session plumbing is testable before Hermes is
wired in. The single Hermes-specific call is isolated in run_hermes_task().
"""
import argparse
import json
import os
import shutil
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROLE = "worker"
CLUSTER = os.environ.get("HERMES_CLUSTER") or os.environ.get("PW_USER") or "unknown"
TASK_TIMEOUT = int(os.environ.get("HERMES_TASK_TIMEOUT", "1800"))

# --- Hermes integration point -------------------------------------------------
# How to run ONE task through the locally-installed Hermes agent.
# CONFIRM the exact headless/run invocation against the Hermes docs:
#   https://hermes-agent.nousresearch.com/docs/
# Override without editing code by exporting $HERMES_TASK_CMD (use {task}).
HERMES_TASK_CMD = os.environ.get("HERMES_TASK_CMD", "")


def run_hermes_task(task, context=""):
    prompt = task if not context else "{}\n\n{}".format(context, task)
    if HERMES_TASK_CMD:
        cmd = HERMES_TASK_CMD.format(task=prompt)
        out = subprocess.run(cmd, shell=True, capture_output=True, text=True,
                             timeout=TASK_TIMEOUT)
        return (out.stdout or out.stderr).strip()
    if shutil.which("hermes"):
        # TODO confirm: single-shot/headless flag for Hermes.
        out = subprocess.run(["hermes", "run", "--prompt", prompt],
                             capture_output=True, text=True, timeout=TASK_TIMEOUT)
        return (out.stdout or out.stderr).strip()
    # Fallback so the whole system is demonstrable before Hermes is installed.
    return "[stub:{}] would run via Hermes: {}".format(CLUSTER, prompt[:300])
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
            self._send(200, {"status": "ok", "role": ROLE, "cluster": CLUSTER})
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
        except Exception as e:  # noqa: BLE001 - surface any failure to the caller
            self._send(500, {"cluster": CLUSTER, "error": str(e)})

    def log_message(self, *a):  # quieter logs; stream to stdout via print if needed
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=int(os.environ.get("service_port", "8717")))
    ap.add_argument("--host", default="0.0.0.0")
    args = ap.parse_args()
    print("hermes worker [{}] listening on {}:{}".format(CLUSTER, args.host, args.port), flush=True)
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
