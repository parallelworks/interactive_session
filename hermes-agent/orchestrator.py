#!/usr/bin/env python3
"""Hermes orchestrator — an OpenAI-compatible agent that coordinates the workers.

Runs on the platform workspace and appears as a chat model in the built-in chat.
It discovers the running per-cluster worker sessions (`pw sessions ls`), and the
brain decides when to delegate tasks to them (tools: list_workers, delegate) and
synthesizes one answer. It reaches each worker over
`pw ssh <cluster> curl localhost:<port>` — hub-and-spoke, no inbound ports.
"""
import argparse
import base64
import json
import os
import subprocess
import time

import hermes_common as hc

MODEL_ID = os.environ.get("HERMES_MODEL_ID", "hermes-orchestrator")
WORKER_MARKER = os.environ.get("HERMES_WORKER_SESSION", "hermes_worker")
FALLBACK_PORT = int(os.environ.get("HERMES_AGENT_PORT") or 8717)
DELEGATE_TIMEOUT = int(os.environ.get("HERMES_DISPATCH_TIMEOUT") or 300)
# When set, reach workers on localhost instead of via `pw ssh` (local testing).
LOCAL_TEST = os.environ.get("HERMES_LOCAL_TEST") == "1"

SYSTEM = (
    "You are the Hermes orchestrator. You coordinate worker agents, one per compute "
    "cluster. Call list_workers to see which clusters are available, then "
    "delegate(cluster, task) to have a cluster's worker run commands there and report "
    "back. To compare clusters (e.g. 'where should I run this GPU job?'), delegate to "
    "each relevant cluster in the SAME turn so they run in parallel, then synthesize "
    "their replies into one clear recommendation. Only delegate to clusters returned by "
    "list_workers."
)
TOOLS = [
    {"type": "function", "function": {
        "name": "list_workers",
        "description": "List the available worker agents (one per cluster).",
        "parameters": {"type": "object", "properties": {}}}},
    {"type": "function", "function": {
        "name": "delegate",
        "description": "Run a task on one cluster's worker agent and return its result.",
        "parameters": {"type": "object", "properties": {
            "cluster": {"type": "string", "description": "cluster name from list_workers"},
            "task": {"type": "string", "description": "what the worker should do, in plain language"}},
            "required": ["cluster", "task"]}}},
]

# `pw sessions ls` is a little slow, and one turn may call delegate several times;
# cache the discovery for a few seconds so we list once per turn, not once per call.
_cache = {"at": 0.0, "workers": []}


def discover_workers(ttl=5):
    """Running worker sessions, found by the marker the worker YAML's `sessions:`
    key puts in the session name. -> [{cluster, port, session}]."""
    now = time.time()
    if _cache["workers"] and now - _cache["at"] < ttl:
        return _cache["workers"]
    try:
        out = subprocess.run(["pw", "sessions", "ls", "-o", "json"],
                             capture_output=True, text=True, timeout=30)
        rows = json.loads(out.stdout or "[]")
    except Exception:  # noqa: BLE001 - no sessions yet / pw not ready -> empty list
        return _cache["workers"]
    rows = rows if isinstance(rows, list) else rows.get("sessions", rows.get("data", []))
    seen, workers = set(), []
    for s in rows:
        name = s.get("name") or ""
        if WORKER_MARKER not in name or s.get("status") != "running":
            continue
        cluster = (s.get("targetName") or "").split("/")[-1]
        if cluster and cluster not in seen:
            seen.add(cluster)
            workers.append({"cluster": cluster,
                            "port": s.get("remotePort") or FALLBACK_PORT,
                            "session": name})
    _cache.update(at=now, workers=workers)
    return workers


def delegate(cluster, task, port):
    """POST {task} to the worker's /task on `cluster`, reached via `pw ssh` (no
    inbound ports needed). `pw ssh` does not forward stdin, so the JSON body is
    base64-encoded into the remote command instead of piped in."""
    payload = base64.b64encode(json.dumps({"task": task}).encode()).decode()
    remote = ("echo %s | base64 -d | curl -s -m %d -X POST "
              "-H 'Content-Type: application/json' --data-binary @- "
              "http://localhost:%d/task") % (payload, DELEGATE_TIMEOUT, port)
    argv = ["bash", "-c", remote] if LOCAL_TEST else ["pw", "ssh", cluster, remote]
    try:
        out = subprocess.run(argv, capture_output=True, text=True, timeout=DELEGATE_TIMEOUT + 60)
    except Exception as exc:  # noqa: BLE001
        return {"cluster": cluster, "ok": False, "error": str(exc)}
    body = (out.stdout or "").strip()
    if out.returncode != 0:
        return {"cluster": cluster, "ok": False,
                "error": (out.stderr or "").strip() or "could not reach worker on %s" % cluster}
    try:
        body = json.loads(body)
    except ValueError:
        pass
    return {"cluster": cluster, "ok": True, "result": body}


def run_tool(name, args):
    if name == "list_workers":
        return [{"cluster": w["cluster"]} for w in discover_workers()]
    if name == "delegate":
        cluster = args.get("cluster", "")
        port = next((w["port"] for w in discover_workers() if w["cluster"] == cluster), FALLBACK_PORT)
        result = delegate(cluster, args.get("task", ""), port)
        return result["result"] if result.get("ok") else result  # surface errors to the brain
    return {"error": "unknown tool: " + name}


def describe(name, args):
    if name == "delegate":
        return "delegating to " + (args.get("cluster") or "?")
    if name == "list_workers":
        return "listing clusters"
    return name


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=int(os.environ.get("service_port") or 8717))
    ap.add_argument("--host", default="0.0.0.0")
    args = ap.parse_args()

    agent = hc.Agent(MODEL_ID, SYSTEM, TOOLS, run_tool, describe)
    hc.serve(MODEL_ID, agent, role="orchestrator", port=args.port, host=args.host,
             get_routes={"/workers": lambda: {"workers": discover_workers()}},
             status=lambda: {"workers": len(discover_workers())})


if __name__ == "__main__":
    main()
