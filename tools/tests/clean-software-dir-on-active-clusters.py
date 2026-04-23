#!/usr/bin/env python3
"""
Run `chmod 777 ~/pw/software && rm -rf ~/pw/software` on all active clusters
via `pw ssh`.

Usage:
    python3 clean-software-dir-on-active-clusters.py
    python3 clean-software-dir-on-active-clusters.py --dry-run
"""

import argparse
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed

REMOTE_CMD = "chmod 777 ${HOME}/pw/software -R; rm -rf ${HOME}/pw/software"

# ── pw helpers ────────────────────────────────────────────────────────────────

def pw(*args, timeout=60) -> tuple[int, str, str]:
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


# ── per-cluster SSH command ───────────────────────────────────────────────────

def run_on_cluster(cluster: dict, dry_run: bool) -> tuple[str, bool, str]:
    name = cluster["name"]
    if dry_run:
        return name, True, f"(dry-run) would run: {REMOTE_CMD}"
    rc, out, err = pw("ssh", name, REMOTE_CMD, timeout=60)
    output = (out + err).strip()
    return name, rc == 0, output


# ── main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="print what would run without executing")
    args = parser.parse_args()

    clusters = get_active_clusters()
    if not clusters:
        print("[ERROR] No active clusters found.")
        sys.exit(1)

    print(f"Active clusters ({len(clusters)}): {', '.join(c['name'] for c in clusters)}")
    if args.dry_run:
        print("[DRY-RUN] No commands will be executed.\n")
    else:
        print(f"Command: {REMOTE_CMD}\n")

    with ThreadPoolExecutor(max_workers=len(clusters)) as pool:
        futures = {pool.submit(run_on_cluster, c, args.dry_run): c for c in clusters}
        results = []
        for fut in as_completed(futures):
            name, ok, detail = fut.result()
            icon = "✓" if ok else "✗"
            print(f"  {icon} {name:20s} {detail}")
            results.append((name, ok))

    failed = [name for name, ok in results if not ok]
    print(f"\n  {len(clusters) - len(failed)}/{len(clusters)} succeeded")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
