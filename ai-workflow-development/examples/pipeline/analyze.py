#!/usr/bin/env python3
"""Stage 2 of the pipeline: least-squares fit of data.csv -> stats.json.

Prints `slope=...` and `mean_y=...` lines — KEY=VALUE format — so the job can
pipe them straight into $OUTPUTS for downstream jobs to consume.
"""
import csv
import json
import statistics as st

xs, ys = [], []
with open("data.csv") as fh:
    next(fh)  # header
    for row in csv.reader(fh):
        xs.append(float(row[0]))
        ys.append(float(row[1]))

n = len(xs)
mx = sum(xs) / n
my = sum(ys) / n
slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sum((x - mx) ** 2 for x in xs)
intercept = my - slope * mx

stats = {
    "n": n,
    "slope": round(slope, 4),
    "intercept": round(intercept, 4),
    "mean_y": round(my, 4),
    "stdev_y": round(st.pstdev(ys), 4),
}
with open("stats.json", "w") as fh:
    json.dump(stats, fh, indent=2)

# KEY=VALUE lines -> $OUTPUTS. good_fit is computed here (in Python, where numeric
# comparisons are reliable) and consumed by a downstream `if:` via string equality.
print("slope=%.4f" % slope)
print("mean_y=%.4f" % my)
print("stdev_y=%.4f" % stats["stdev_y"])
print("good_fit=%s" % ("true" if 2.0 <= slope <= 4.0 else "false"))
