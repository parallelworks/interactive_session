#!/usr/bin/env python3
"""Estimate pi by Monte Carlo sampling, in batches, with live progress.

Pure standard library (no pip installs). Designed to run as a *batch* job via
script_submitter: progress lines stream to run.<JOBID>.out so the user sees life,
and a structured result is written to montecarlo_result.json in --out-dir.

This is a compute workload (no web server / session) — the counterpart to the
fractal example, which is a session workload.
"""
import argparse
import json
import math
import os
import random
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--samples", type=int, default=12_000_000, help="total points to sample")
    ap.add_argument("--batches", type=int, default=24, help="progress reports")
    ap.add_argument("--seed", type=int, default=12345)
    ap.add_argument("--out-dir", default=".")
    args = ap.parse_args()

    rnd = random.Random(args.seed)
    per = max(1, args.samples // args.batches)
    total = per * args.batches
    node = os.uname().nodename
    cpus = os.cpu_count() or 1

    print("::notice::host=%s cpus=%d pid=%d samples=%d batches=%d"
          % (node, cpus, os.getpid(), total, args.batches), flush=True)

    inside = 0
    done = 0
    t0 = time.time()
    for b in range(args.batches):
        for _ in range(per):
            x = rnd.random()
            y = rnd.random()
            if x * x + y * y <= 1.0:
                inside += 1
        done += per
        est = 4.0 * inside / done
        print("::notice::batch %2d/%d  %5.1f%%  pi~=%.6f  (%d/%d)"
              % (b + 1, args.batches, 100.0 * done / total, est, done, total), flush=True)

    pi = 4.0 * inside / done
    elapsed = time.time() - t0
    result = {
        "pi_estimate": pi,
        "abs_error": abs(pi - math.pi),
        "samples": done,
        "inside": inside,
        "elapsed_s": round(elapsed, 3),
        "host": node,
        "cpus": cpus,
    }
    out = os.path.join(args.out_dir, "montecarlo_result.json")
    with open(out, "w") as fh:
        json.dump(result, fh, indent=2)
    print("::notice::DONE pi=%.6f abs_error=%.2e in %.1fs -> %s"
          % (pi, result["abs_error"], elapsed, out), flush=True)


if __name__ == "__main__":
    main()
