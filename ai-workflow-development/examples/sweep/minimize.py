#!/usr/bin/env python3
"""One worker of a parameter sweep: grid-search the minimum of Himmelblau's
function over an x-band, writing part_<id>.json. Run concurrently by sibling
jobs over different bands; an aggregator merges the parts.
"""
import argparse
import json
import time

ap = argparse.ArgumentParser()
ap.add_argument("--id", required=True)
ap.add_argument("--lo", type=float, required=True)
ap.add_argument("--hi", type=float, required=True)
ap.add_argument("--steps", type=int, default=240)
a = ap.parse_args()


def f(x, y):  # Himmelblau: 4 global minima of 0
    return (x * x + y - 11) ** 2 + (x + y * y - 7) ** 2


best = None
for i in range(a.steps):
    x = a.lo + (a.hi - a.lo) * i / (a.steps - 1)
    for j in range(a.steps):
        y = -6.0 + 12.0 * j / (a.steps - 1)
        v = f(x, y)
        if best is None or v < best[0]:
            best = (v, x, y)

part = {"id": a.id, "band": [a.lo, a.hi], "min": round(best[0], 6),
        "x": round(best[1], 4), "y": round(best[2], 4),
        "finished_at": time.strftime("%H:%M:%S")}
with open("part_%s.json" % a.id, "w") as fh:
    json.dump(part, fh)
print("::notice::worker %s band[%g,%g] min=%.4f at (%.3f,%.3f)"
      % (a.id, a.lo, a.hi, best[0], best[1], best[2]))
