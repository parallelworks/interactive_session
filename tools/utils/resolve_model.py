#!/usr/bin/env python3
"""Resolve a brain-model name to the id the ACTIVATE OpenAI endpoint routes by.

The platform routes by a fully-qualified id -- 'org:owner/provider', or for a
session-served model 'session:user:provider/model'. The Chat model picker only
shows the short trailing name (e.g. '/gpt-oss-20b', 'glm-5.1'); sending that
verbatim fails with 400 "Invalid provider identifier format". This maps a short
name to its full id by matching GET /v1/models, and warns when the configured
name is not already an exact id.

Shared, identical, by three workflows: lite-agent and agent-orchestrator import
`resolve_model(...)`; hermes-agent runs it as a CLI to resolve the model before
writing it into Hermes' config. Standard library only -- runs on a clean Python 3.

CLI (prints the resolved id to stdout; warnings go to stderr):
    python3 resolve_model.py [MODEL] [--base-url URL] [--api-key KEY] [--allocation NAME]
    # MODEL/--base-url/--api-key/--allocation default to env
    # MODEL / OPENAI_BASE_URL / OPENAI_API_KEY (or PW_API_KEY) / X_ALLOCATION.
"""
import json
import os
import sys
import urllib.request


def fetch_models(base_url, api_key, allocation="", timeout=30):
    """GET {base_url}/models -> list of model dicts ({id, name, ...}).
    Empty list on any error so resolution degrades to using the literal name."""
    base_url = (base_url or "").rstrip("/")
    if not base_url or not api_key:
        return []
    headers = {"Authorization": "Bearer " + api_key}
    if allocation:
        headers["X-Allocation"] = allocation
    try:
        req = urllib.request.Request(base_url + "/models", headers=headers)
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.load(resp)
        return data.get("data", []) if isinstance(data, dict) else []
    except Exception:  # noqa: BLE001 - resolution is best-effort
        return []


def match_model(want, models):
    """(resolved_id, exact) for `want` against `models`.

    A name that already carries a provider prefix (':') is taken as-is/exact. A
    bare name is matched, in order, by exact id, by the id's trailing segment
    (so 'gpt-oss-20b' finds 'session:..//gpt-oss-20b'), then by the parenthetical
    display name. No match returns (want, False) so the caller fails loudly."""
    want = (want or "").strip()
    if not want or ":" in want:
        return want, True
    for m in models:
        if m.get("id") == want:
            return want, True
    tail = want.lstrip("/")
    for m in models:
        mid = m.get("id", "")
        if mid.rsplit("/", 1)[-1] == tail:
            return mid, False
    for m in models:
        name = m.get("name", "")
        if "(" in name and name.rsplit("(", 1)[-1].rstrip(")").strip().lstrip("/") == tail:
            return m.get("id", want), False
    return want, False


def resolve_model(want, base_url, api_key, allocation="", warn=True):
    """Resolve `want` to a routable model id, warning (stderr) when it was not an
    exact id: either it mapped to a different id, or nothing matched. A name that
    already carries a provider prefix (':') is returned unchanged without a lookup."""
    want = (want or "").strip()
    if ":" in want:
        return want
    resolved, exact = match_model(want, fetch_models(base_url, api_key, allocation))
    if warn and not exact:
        if resolved != want:
            sys.stderr.write("resolve_model: %r is not an exact model id; using %r "
                             "(matched via GET /v1/models)\n" % (want, resolved))
        else:
            sys.stderr.write("resolve_model: WARNING %r matched no model in GET /v1/models; "
                             "using it as-is -- the brain call will fail if it is not routable\n" % want)
    return resolved


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(description="Resolve a brain-model name to its full ACTIVATE id.")
    ap.add_argument("model", nargs="?", default=os.environ.get("MODEL", ""))
    ap.add_argument("--base-url", default=os.environ.get("OPENAI_BASE_URL", ""))
    ap.add_argument("--api-key", default=os.environ.get("OPENAI_API_KEY") or os.environ.get("PW_API_KEY", ""))
    ap.add_argument("--allocation", default=os.environ.get("X_ALLOCATION", ""))
    args = ap.parse_args(argv)
    sys.stdout.write(resolve_model(args.model, args.base_url, args.api_key, args.allocation) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
