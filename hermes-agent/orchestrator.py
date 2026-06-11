#!/usr/bin/env python3
"""Hermes ORCHESTRATOR -- coordinates worker agents across clusters.

Runs on the platform workspace. Holds the roster of worker clusters and reaches
each worker over the hub-and-spoke transport:

    pw ssh <cluster> 'curl localhost:<agent_port>/task'

That reuses the pw client's auth, opens no inbound ports, and works regardless of
where each cluster lives. It exposes itself over HTTP so you can drive it from the
session UI (or curl it).

Endpoints
  GET  /  and  /health   -> {"status":"ok","workers":[...]}
  POST /run              -> {"goal":"..."}   decide delegation, dispatch, aggregate

Stdlib only, so the coordination/transport is testable before the Hermes
coordinator is wired in (the integration point is run_goal()).
"""
import argparse
import base64
import json
import os
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROLE = "orchestrator"
WORKERS = [c.strip() for c in os.environ.get("HERMES_WORKERS", "").split(",") if c.strip()]
AGENT_PORT = os.environ.get("HERMES_AGENT_PORT", "8717")
DISPATCH_TIMEOUT = int(os.environ.get("HERMES_DISPATCH_TIMEOUT", "1800"))
# Set HERMES_LOCAL_TEST=1 to reach a worker on localhost (skips pw ssh) for testing.
LOCAL_TEST = os.environ.get("HERMES_LOCAL_TEST") == "1"


def delegate(cluster, task, context=""):
    """Send one task to a worker on <cluster> and return its result."""
    payload = json.dumps({"task": task, "context": context})
    b64 = base64.b64encode(payload.encode()).decode()
    # base64 the payload so we never depend on stdin forwarding through pw ssh.
    remote = ("echo {b} | base64 -d | "
              "curl -s -m {to} -X POST -H 'Content-Type: application/json' "
              "--data-binary @- http://localhost:{port}/task"
              ).format(b=b64, to=DISPATCH_TIMEOUT, port=AGENT_PORT)
    if LOCAL_TEST:
        argv = ["bash", "-c", remote]
    else:
        argv = ["pw", "ssh", cluster, remote]
    try:
        out = subprocess.run(argv, capture_output=True, text=True,
                             timeout=DISPATCH_TIMEOUT + 60)
        body = (out.stdout or "").strip()
        try:
            body = json.loads(body)
        except Exception:
            pass
        return {"cluster": cluster, "ok": out.returncode == 0,
                "result": body, "stderr": (out.stderr or "").strip()[:500]}
    except Exception as e:  # noqa: BLE001
        return {"cluster": cluster, "ok": False, "error": str(e)}


def run_goal(goal):
    """Turn a high-level goal into per-worker tasks and aggregate the results.

    Integration point: hand `goal` to a Hermes COORDINATOR agent whose delegate
    tool calls delegate(cluster, task) above -- the coordinator decides which
    cluster does what. CONFIRM the coordinator/custom-tool wiring against the
    Hermes multi-agent docs:
        https://hermes-agent.ai/features/multi-agent
    v1 fallback below: broadcast the goal to every worker and collect results.
    """
    results = [delegate(c, goal) for c in WORKERS]
    return {"goal": goal, "workers": WORKERS, "results": results}


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
            self._send(200, {"status": "ok", "role": ROLE, "workers": WORKERS})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/run":
            self._send(404, {"error": "not found"})
            return
        try:
            n = int(self.headers.get("Content-Length", 0))
            req = json.loads(self.rfile.read(n) or b"{}")
            self._send(200, run_goal(req.get("goal", "")))
        except Exception as e:  # noqa: BLE001
            self._send(500, {"error": str(e)})

    def log_message(self, *a):
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=int(os.environ.get("service_port", "8717")))
    ap.add_argument("--host", default="0.0.0.0")
    args = ap.parse_args()
    print("hermes orchestrator listening on {}:{} | workers={}".format(
        args.host, args.port, WORKERS), flush=True)
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
