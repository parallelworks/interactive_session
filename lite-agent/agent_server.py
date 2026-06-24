#!/usr/bin/env python3
"""Lite agent — a small OpenAI-compatible agent for ONE cluster.

Runs on a cluster's login node. It answers by running shell commands on THIS
machine (the brain's run_shell tool) and reasoning over the real output, so you
can ask it about the cluster or have it start and check on work there.

The workflow declares it `openAI: true`, so it appears as a chat model and the
agent-orchestrator can discover it. It advertises its fleet **marker** at
`GET /_agent` so an orchestrator with the same marker picks it up.
"""
import argparse
import os
import subprocess

import agent_common as hc

CLUSTER = os.environ.get("AGENT_CLUSTER") or os.environ.get("PW_USER") or "this cluster"
MODEL_ID = os.environ.get("AGENT_MODEL_ID", "lite-agent")
MARKER = os.environ.get("AGENT_MARKER", "worker")
SHELL_TIMEOUT = int(os.environ.get("AGENT_SHELL_TIMEOUT") or 60)

DEFAULT_SYSTEM = (
    "You are an agent running on the compute cluster '{cluster}'. Use the run_shell "
    "tool to inspect or act on THIS machine and answer from real command output — never "
    "guess. For long-running work (simulations, training, big downloads), submit it to "
    "the scheduler or start it in the background and report how to check on it; do not "
    "block waiting for it to finish. Keep answers concise and specific to this cluster."
)
# The workflow form can override this; falls back to DEFAULT_SYSTEM (see agent_common).
# "{cluster}" in the prompt is replaced with this worker's cluster name.
SYSTEM = hc.load_system_prompt(DEFAULT_SYSTEM).replace("{cluster}", CLUSTER)
TOOLS = [{
    "type": "function",
    "function": {
        "name": "run_shell",
        "description": "Run a shell command on this cluster and return its combined output.",
        "parameters": {"type": "object",
                       "properties": {"command": {"type": "string"}},
                       "required": ["command"]}}}]


def run_shell(command):
    if not command:
        return "(no command given)"
    try:
        out = subprocess.run(command, shell=True, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, universal_newlines=True,
                             timeout=SHELL_TIMEOUT)
    except subprocess.TimeoutExpired:
        return "(command timed out after %ss)" % SHELL_TIMEOUT
    text = ((out.stdout or "") + (out.stderr or "")).strip()
    return text or "(no output; exit code %d)" % out.returncode


def run_tool(name, args):
    if name == "run_shell":
        return run_shell(args.get("command", ""))
    return {"error": "unknown tool: " + name}


def describe(name, args):
    if name == "run_shell":
        cmd = args.get("command", "")
        return "run on %s: %s" % (CLUSTER, cmd if len(cmd) <= 80 else cmd[:77] + "…")
    return name


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=int(os.environ.get("service_port") or 8717))
    ap.add_argument("--host", default="0.0.0.0")
    args = ap.parse_args()

    agent = hc.Agent(MODEL_ID, SYSTEM, TOOLS, run_tool, describe)

    hc.serve(MODEL_ID, route=lambda req: agent, list_models=lambda: [MODEL_ID],
             role="worker", port=args.port, host=args.host,
             get_routes={"/_agent": lambda: {"marker": MARKER, "kind": "lite",
                                             "model": MODEL_ID, "cluster": CLUSTER}},
             status=lambda: {"cluster": CLUSTER, "marker": MARKER})


if __name__ == "__main__":
    main()
