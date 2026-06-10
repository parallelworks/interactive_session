#!/usr/bin/env python3
"""Stage 1 of the pipeline: generate a noisy linear dataset to data.csv.

Prints the row count on stdout so the job can capture it into $OUTPUTS.
"""
import argparse
import csv
import random

ap = argparse.ArgumentParser()
ap.add_argument("--rows", type=int, default=1000)
ap.add_argument("--noise", type=float, default=2.0)
ap.add_argument("--slope", type=float, default=3.0)
ap.add_argument("--intercept", type=float, default=5.0)
ap.add_argument("--seed", type=int, default=7)
ap.add_argument("--out", default="data.csv")
a = ap.parse_args()

rnd = random.Random(a.seed)
with open(a.out, "w", newline="") as fh:
    w = csv.writer(fh)
    w.writerow(["x", "y"])
    for i in range(a.rows):
        x = i / a.rows * 10.0
        y = a.slope * x + a.intercept + rnd.gauss(0, a.noise)
        w.writerow([round(x, 4), round(y, 4)])

print(a.rows)
