#!/usr/bin/env python3
"""Fan-in: merge all part_*.json from the sweep workers, pick the global min,
and write sweep_result.json with a ranking.
"""
import glob
import json

parts = [json.load(open(p)) for p in sorted(glob.glob("part_*.json"))]
if not parts:
    raise SystemExit("no part_*.json found — did the workers run?")

ranked = sorted(parts, key=lambda d: d["min"])
best = ranked[0]
result = {
    "workers": len(parts),
    "global_min": best["min"],
    "x": best["x"],
    "y": best["y"],
    "ranking": ranked,
    "finished_times": [p.get("finished_at") for p in parts],
}
with open("sweep_result.json", "w") as fh:
    json.dump(result, fh, indent=2)

print("::notice::GLOBAL MIN=%.4f at (%.3f,%.3f) across %d workers"
      % (best["min"], best["x"], best["y"], len(parts)))
for p in ranked:
    print("  worker %s band%s -> min=%.4f (finished %s)"
          % (p["id"], p["band"], p["min"], p.get("finished_at")))
