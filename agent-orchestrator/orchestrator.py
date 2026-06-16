#!/usr/bin/env python3
"""Agent orchestrator — coordinates per-cluster agents (lite-agent or Hermes).

Runs on the platform workspace and appears as a chat model in the built-in chat.
It discovers running worker agents, and the brain decides when to ask each
(tools: list_clusters, ask_cluster) and synthesizes one answer. It reaches each
worker over `pw ssh <cluster> curl localhost:<port>/v1/chat/completions` —
hub-and-spoke, no inbound ports.

Workers are grouped by a **marker** (a launch-time form value, default "worker").
The orchestrator only sees workers whose marker matches its own, so independent
fleets (e.g. "gpuworker") don't mix. The marker can't live in the session name
(that's fixed per workflow), so each worker advertises it over HTTP at `/_agent`
and the orchestrator probes candidates to learn theirs.
"""
import argparse
import base64
import json
import os
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

import agent_common as hc

MARKER = os.environ.get("AGENT_MARKER", "worker")
MODEL_ID = os.environ.get("AGENT_ORCH_MODEL_ID") or (MARKER + "-orchestrator")
ASK_TIMEOUT = int(os.environ.get("AGENT_ASK_TIMEOUT") or 300)
# When set, reach workers on localhost instead of via `pw ssh` (local testing).
LOCAL_TEST = os.environ.get("AGENT_LOCAL_TEST") == "1"

SYSTEM = (
    "You are an orchestrator that coordinates agents, one per compute cluster. Call "
    "list_clusters to see which clusters are available, then ask_cluster(cluster, "
    "question) to have that cluster's agent inspect or act on its machine and report "
    "back. To compare clusters (e.g. 'where should I run this GPU job?'), ask each "
    "relevant cluster in the SAME turn so they run in parallel, then synthesize their "
    "replies into one clear recommendation. Only ask clusters returned by list_clusters."
)
TOOLS = [
    {"type": "function", "function": {
        "name": "list_clusters",
        "description": "List the clusters that have an agent available.",
        "parameters": {"type": "object", "properties": {}}}},
    {"type": "function", "function": {
        "name": "ask_cluster",
        "description": "Ask one cluster's agent a question; it can run commands there and reports back.",
        "parameters": {"type": "object", "properties": {
            "cluster": {"type": "string", "description": "cluster name from list_clusters"},
            "question": {"type": "string", "description": "what to ask that cluster's agent, in plain language"}},
            "required": ["cluster", "question"]}}},
]

_cache = {"at": 0.0, "workers": []}


def _pw_ssh(cluster, remote):
    return ["bash", "-c", remote] if LOCAL_TEST else ["pw", "ssh", cluster, remote]


def probe_marker(cluster, port):
    """Read a candidate worker's advertised marker from its `/_agent` endpoint."""
    remote = "curl -s -m 5 http://localhost:%d/_agent" % port
    try:
        out = subprocess.run(_pw_ssh(cluster, remote), capture_output=True, text=True, timeout=40)
        return (json.loads(out.stdout) or {}).get("marker")
    except Exception:  # noqa: BLE001 - not an agent / unreachable -> no marker
        return None


def discover_workers(ttl=5):
    """Running worker sessions whose advertised marker matches MARKER.
    Candidates are openAI-enabled cluster sessions (from `pw sessions ls`); we
    probe each one's `/_agent` for its marker and keep the matches.
    -> [{cluster, port}]."""
    now = time.time()
    if _cache["workers"] and now - _cache["at"] < ttl:
        return _cache["workers"]
    try:
        out = subprocess.run(["pw", "sessions", "ls", "-o", "json"],
                             capture_output=True, text=True, timeout=30)
        rows = json.loads(out.stdout or "[]")
    except Exception:  # noqa: BLE001
        return _cache["workers"]
    rows = rows if isinstance(rows, list) else rows.get("sessions", rows.get("data", []))
    cands = []
    for s in rows:
        # any non-workspace agent session (cluster, existing, ...) is a candidate
        if s.get("status") != "running" or not s.get("openAI") or s.get("targetType") == "workspace":
            continue
        cluster = (s.get("targetName") or "").split("/")[-1]
        port = s.get("remotePort")
        if cluster and port:
            cands.append((cluster, port))
    workers, seen = [], set()
    if cands:
        with ThreadPoolExecutor(max_workers=min(16, len(cands))) as pool:
            futs = {pool.submit(probe_marker, c, p): (c, p) for c, p in cands}
            for fut in as_completed(futs):
                c, p = futs[fut]
                if fut.result() == MARKER and c not in seen:
                    seen.add(c)
                    workers.append({"cluster": c, "port": p})
    _cache.update(at=now, workers=workers)
    return workers


def ask_worker(cluster, port, messages):
    """POST a conversation to the cluster agent's `/v1/chat/completions`, reached
    via `pw ssh` (no inbound ports). `pw ssh` does not forward stdin, so the JSON
    body is base64-encoded into the remote command instead of piped in."""
    body = {"model": "agent", "messages": messages, "stream": False}
    payload = base64.b64encode(json.dumps(body).encode()).decode()
    remote = ("echo %s | base64 -d | curl -s -m %d -X POST "
              "-H 'Content-Type: application/json' --data-binary @- "
              "http://localhost:%d/v1/chat/completions") % (payload, ASK_TIMEOUT, port)
    try:
        out = subprocess.run(_pw_ssh(cluster, remote), capture_output=True, text=True, timeout=ASK_TIMEOUT + 60)
    except Exception as exc:  # noqa: BLE001
        return "(could not reach %s: %s)" % (cluster, exc)
    try:
        return json.loads(out.stdout)["choices"][0]["message"]["content"]
    except Exception:  # noqa: BLE001
        return (out.stdout or out.stderr or "").strip() or "(no response from %s)" % cluster


def run_tool(name, args):
    if name == "list_clusters":
        return [{"cluster": w["cluster"]} for w in discover_workers()]
    if name == "ask_cluster":
        cluster = args.get("cluster", "")
        w = next((w for w in discover_workers() if w["cluster"] == cluster), None)
        if not w:
            return {"error": "unknown cluster: " + cluster}
        return {"cluster": cluster,
                "answer": ask_worker(cluster, w["port"], [{"role": "user", "content": args.get("question", "")}])}
    return {"error": "unknown tool: " + name}


def describe(name, args):
    if name == "ask_cluster":
        return "asking " + (args.get("cluster") or "?")
    if name == "list_clusters":
        return "listing clusters"
    return name


def worker_model_id(cluster):
    """Chat-model id advertised for a single cluster, e.g. 'worker-gcpsmall'."""
    return MARKER + "-" + cluster


class WorkerProxy:
    """Responder that sends a chat straight to one cluster's agent, so each
    cluster is selectable as its own chat model next to the orchestrator."""

    def __init__(self, cluster, port):
        self.cluster = cluster
        self.port = port

    def answer(self, messages):
        return ask_worker(self.cluster, self.port, messages)

    def run(self, messages):
        yield "step", "↪ " + self.cluster
        yield "answer", self.answer(messages)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=int(os.environ.get("service_port") or 8718))
    ap.add_argument("--host", default="0.0.0.0")
    args = ap.parse_args()

    orchestrator = hc.Agent(MODEL_ID, SYSTEM, TOOLS, run_tool, describe)

    def route(req):
        requested = (req.get("model") or "").split("/")[-1]
        for w in discover_workers():
            if requested == worker_model_id(w["cluster"]):
                return WorkerProxy(w["cluster"], w["port"])
        return orchestrator

    def list_models():
        return [MODEL_ID] + [worker_model_id(w["cluster"]) for w in discover_workers()]

    print("agent-orchestrator marker=%r model=%r" % (MARKER, MODEL_ID), flush=True)
    hc.serve(MODEL_ID, route=route, list_models=list_models,
             role="orchestrator", port=args.port, host=args.host,
             get_routes={"/clusters": lambda: {"marker": MARKER, "clusters": discover_workers()}},
             status=lambda: {"marker": MARKER, "clusters": len(discover_workers())})


if __name__ == "__main__":
    main()
