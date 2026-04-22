#!/usr/bin/env python3
"""
Test runner: launches each workflow on every active cluster, waits for session
creation (or error), cancels successful sessions, and prints a summary.

Usage:
    python3 run-tests.py
    python3 run-tests.py --workflows marketplace.desktop.latest marketplace.jupyter.latest
    python3 run-tests.py --timeout 1200
"""

import argparse
import json
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field

# ── defaults ─────────────────────────────────────────────────────────────────

DEFAULT_WORKFLOWS = [
    "marketplace.desktop.latest",
    "marketplace.jupyterlab.latest",
    "marketplace.openvscode.latest"
]

POLL_INTERVAL = 30   # seconds between status checks
MAX_POLLS     = 40   # 40 × 30 s ≈ 20 min timeout per run

# ─────────────────────────────────────────────────────────────────────────────


@dataclass
class RunRecord:
    workflow: str
    cluster: str
    cluster_uri: str
    slug: str = ""
    number: int = 0
    result: str = "PENDING"   # PENDING | SUCCESS | FAILED | TIMEOUT | LAUNCH_ERROR
    detail: str = ""
    errors: list = field(default_factory=list)


# ── pw helpers ────────────────────────────────────────────────────────────────

def pw(*args, timeout=30) -> tuple[int, str, str]:
    r = subprocess.run(["pw"] + list(args), capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout, r.stderr


def get_active_clusters() -> list[dict]:
    rc, out, err = pw("cluster", "list")
    if rc != 0:
        print(f"[ERROR] pw cluster list failed: {err}", file=sys.stderr)
        sys.exit(1)
    clusters = []
    for line in out.strip().splitlines()[1:]:  # skip header
        parts = line.split()
        if len(parts) >= 2 and parts[1] == "active":
            uri = parts[0]
            name = uri.split("/")[-1]
            clusters.append({"uri": uri, "name": name})
    return clusters


def launch_workflow(workflow: str, cluster_uri: str) -> tuple[str, int, str]:
    """Returns (slug, number, error_message). error_message is empty on success."""
    inputs = json.dumps({"resource": cluster_uri})
    rc, out, err = pw("workflow", "run", "-i", inputs, "-o", "json", workflow, timeout=60)
    if rc != 0:
        return "", 0, (err or out).strip()
    try:
        data = json.loads(out)
        run = data["run"]
        return run["slug"], run.get("number", 0), ""
    except Exception as e:
        return "", 0, f"could not parse response: {e}\n{out}"


def get_run(slug: str) -> dict:
    rc, out, err = pw("workflow", "runs", "view", slug, "-o", "json", timeout=30)
    if rc != 0:
        raise RuntimeError(f"view failed: {err.strip()}")
    return json.loads(out)


def cancel_run(slug: str) -> bool:
    rc, _, _ = pw("workflow", "runs", "cancel", slug, timeout=30)
    return rc == 0


def session_created(data: dict) -> tuple[bool, str]:
    """Return (True, step_name) once the session has been registered on the platform."""
    sr_steps = data.get("executedJobs", {}).get("session_runner", {}).get("steps", [])
    if not sr_steps:
        return False, ""
    subwf_jobs = sr_steps[0].get("subworkflow", {}).get("jobs", {})
    for step in subwf_jobs.get("create_session", {}).get("steps", []):
        if step.get("name") in ("Session Ready", "Update Session") and step.get("status") == "completed":
            return True, step["name"]
    return False, ""


def collect_errors(data: dict) -> list[str]:
    msgs = []
    def walk(obj):
        if isinstance(obj, dict):
            for a in obj.get("annotations", []):
                if a.get("type") == "error":
                    msgs.append(a.get("message", ""))
            for v in obj.values():
                walk(v)
        elif isinstance(obj, list):
            for item in obj:
                walk(item)
    walk(data.get("executedJobs", {}))
    return msgs


# ── per-run monitor (runs in a thread) ───────────────────────────────────────

def monitor_run(record: RunRecord) -> RunRecord:
    for poll in range(1, MAX_POLLS + 1):
        try:
            data = get_run(record.slug)
        except Exception as e:
            record.result = "FAILED"
            record.detail = f"polling error: {e}"
            return record

        status = data.get("status", "?")

        if status == "error":
            errs = collect_errors(data)
            record.result = "FAILED"
            record.detail = "; ".join(errs[:2]) if errs else "error status"
            record.errors = errs
            return record

        if status in ("canceled", "completed"):
            record.result = "FAILED"
            record.detail = f"unexpectedly reached status '{status}' before session was confirmed"
            return record

        if status == "running":
            created, step_name = session_created(data)
            if created:
                ok = cancel_run(record.slug)
                record.result = "SUCCESS"
                record.detail = f"session created ({step_name}), canceled ok={ok}"
                return record

        if poll < MAX_POLLS:
            time.sleep(POLL_INTERVAL)

    record.result = "TIMEOUT"
    record.detail = f"exceeded {MAX_POLLS * POLL_INTERVAL // 60} min"
    return record


# ── launch stage (sequential per workflow to avoid slug conflicts) ─────────────

def launch_all(workflows: list[str], clusters: list[dict]) -> list[RunRecord]:
    records = []
    for workflow in workflows:
        print(f"\n[LAUNCH] {workflow}")
        for cluster in clusters:
            record = RunRecord(
                workflow=workflow,
                cluster=cluster["name"],
                cluster_uri=cluster["uri"],
            )
            slug, number, err = launch_workflow(workflow, cluster["uri"])
            if err:
                record.result = "LAUNCH_ERROR"
                record.detail = err
                print(f"  {cluster['name']:20s} → LAUNCH ERROR: {err}")
            else:
                record.slug = slug
                record.number = number
                print(f"  {cluster['name']:20s} → #{number} {slug}")
            records.append(record)
    return records


# ── monitor stage (parallel across all runs) ─────────────────────────────────

def monitor_all(records: list[RunRecord]) -> list[RunRecord]:
    pending = [r for r in records if r.result == "PENDING"]
    done    = [r for r in records if r.result != "PENDING"]

    if not pending:
        return done

    print(f"\n[MONITOR] watching {len(pending)} run(s) …")
    with ThreadPoolExecutor(max_workers=len(pending)) as pool:
        futures = {pool.submit(monitor_run, r): r for r in pending}
        for fut in as_completed(futures):
            r = fut.result()
            icon = "✓" if r.result == "SUCCESS" else "✗"
            num = f"#{r.number}" if r.number else ""
            print(f"  {icon} {r.workflow} / {r.cluster:20s} [{r.slug} {num}]: {r.result} — {r.detail}")

    return done + [fut.result() for fut in futures]


# ── summary ───────────────────────────────────────────────────────────────────

def print_summary(records: list[RunRecord]) -> None:
    workflows = sorted({r.workflow for r in records})
    clusters  = sorted({r.cluster  for r in records})

    col_w = max(len(c) for c in clusters) + 2

    print("\n" + "=" * 70)
    print("SUMMARY")
    print("=" * 70)

    for workflow in workflows:
        print(f"\n  {workflow}")
        wf_records = [r for r in records if r.workflow == workflow]
        success = sum(1 for r in wf_records if r.result == "SUCCESS")
        total   = len(wf_records)
        for r in sorted(wf_records, key=lambda x: x.cluster):
            icon = "PASS" if r.result == "SUCCESS" else "FAIL"
            ref = f"[#{r.number} {r.slug}]" if r.slug else ""
            print(f"    {icon}  {r.cluster:{col_w}s} {ref:32s} {r.detail}")
        print(f"  → {success}/{total} passed")

    total_pass = sum(1 for r in records if r.result == "SUCCESS")
    print(f"\n  TOTAL: {total_pass}/{len(records)} passed")
    print("=" * 70)


# ── main ──────────────────────────────────────────────────────────────────────

def main():
    global MAX_POLLS
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--workflows", nargs="+", default=DEFAULT_WORKFLOWS,
                        help="workflow name(s) to test (default: %(default)s)")
    parser.add_argument("--timeout", type=int, default=MAX_POLLS * POLL_INTERVAL,
                        help="per-run timeout in seconds (default: %(default)s)")
    args = parser.parse_args()
    MAX_POLLS = max(1, args.timeout // POLL_INTERVAL)

    clusters = get_active_clusters()
    if not clusters:
        print("[ERROR] No active clusters found.")
        sys.exit(1)

    print(f"Active clusters ({len(clusters)}): {', '.join(c['name'] for c in clusters)}")
    print(f"Workflows to test ({len(args.workflows)}): {', '.join(args.workflows)}")

    records = launch_all(args.workflows, clusters)
    records = monitor_all(records)
    print_summary(records)

    failed = sum(1 for r in records if r.result != "SUCCESS")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
