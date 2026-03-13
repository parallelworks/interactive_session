#!/usr/bin/env python3
"""
Flask dashboard for FEniCS topology optimization.
Reads results from the output directory and serves live density field
and convergence plots.
"""

import argparse
import csv
import io
import json
import os

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from flask import Flask, render_template, send_file, jsonify

app = Flask(__name__)
RESULTS_DIR = None


def read_status():
    path = os.path.join(RESULTS_DIR, "status.json")
    if not os.path.exists(path):
        return {"state": "waiting", "iteration": 0}
    try:
        with open(path, "r") as f:
            return json.load(f)
    except (json.JSONDecodeError, IOError):
        return {"state": "waiting", "iteration": 0}


def get_latest_iteration():
    return read_status().get("iteration", 0)


def make_placeholder(msg):
    fig, ax = plt.subplots(figsize=(10, 5))
    ax.text(0.5, 0.5, msg, ha="center", va="center", fontsize=16, transform=ax.transAxes)
    ax.set_axis_off()
    buf = io.BytesIO()
    fig.savefig(buf, format="png", dpi=100, bbox_inches="tight")
    plt.close(fig)
    buf.seek(0)
    return buf


@app.route("/")
def index():
    status = read_status()
    return render_template("index.html", status=status)


@app.route("/api/status")
def api_status():
    return jsonify(read_status())


@app.route("/plot/density.png")
def density_plot():
    iteration = get_latest_iteration()
    if iteration == 0:
        return send_file(make_placeholder("Waiting for simulation to start..."), mimetype="image/png")

    density_path = os.path.join(RESULTS_DIR, f"density_{iteration:04d}.npy")
    midpoints_path = os.path.join(RESULTS_DIR, "cell_midpoints.npy")
    domain_path = os.path.join(RESULTS_DIR, "domain_info.json")

    if not os.path.exists(density_path) or not os.path.exists(midpoints_path):
        return send_file(make_placeholder("Loading..."), mimetype="image/png")

    rho = np.load(density_path)
    midpoints = np.load(midpoints_path)
    with open(domain_path) as f:
        domain_info = json.load(f)

    nelx = domain_info["nelx"]
    nely = domain_info["nely"]

    fig, ax = plt.subplots(figsize=(10, 5))
    sc = ax.tripcolor(
        midpoints[:, 0], midpoints[:, 1], rho,
        cmap="binary_r", vmin=0.0, vmax=1.0, shading="flat",
    )
    ax.set_xlim(0, nelx)
    ax.set_ylim(0, nely)
    ax.set_aspect("equal")
    ax.set_title(f"Density Field (Iteration {iteration})", fontsize=14)
    plt.colorbar(sc, ax=ax, label="Density")
    ax.set_xlabel("x")
    ax.set_ylabel("y")

    buf = io.BytesIO()
    fig.savefig(buf, format="png", dpi=100, bbox_inches="tight")
    plt.close(fig)
    buf.seek(0)
    return send_file(buf, mimetype="image/png")


@app.route("/plot/convergence.png")
def convergence_plot():
    conv_path = os.path.join(RESULTS_DIR, "convergence.csv")
    if not os.path.exists(conv_path):
        return send_file(make_placeholder("Waiting for data..."), mimetype="image/png")

    iterations, compliances, volumes = [], [], []
    try:
        with open(conv_path, "r") as f:
            reader = csv.DictReader(f)
            for row in reader:
                iterations.append(int(row["iteration"]))
                compliances.append(float(row["compliance"]))
                volumes.append(float(row["volume_fraction"]))
    except (IOError, KeyError, ValueError):
        pass

    if not iterations:
        return send_file(make_placeholder("No data yet"), mimetype="image/png")

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 4))

    ax1.plot(iterations, compliances, "b-o", markersize=2)
    ax1.set_xlabel("Iteration")
    ax1.set_ylabel("Compliance")
    ax1.set_title("Compliance History")
    ax1.grid(True, alpha=0.3)

    ax2.plot(iterations, volumes, "r-o", markersize=2)
    ax2.set_xlabel("Iteration")
    ax2.set_ylabel("Volume Fraction")
    ax2.set_title("Volume Fraction History")
    ax2.grid(True, alpha=0.3)

    fig.tight_layout()
    buf = io.BytesIO()
    fig.savefig(buf, format="png", dpi=100, bbox_inches="tight")
    plt.close(fig)
    buf.seek(0)
    return send_file(buf, mimetype="image/png")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--results-dir", type=str, required=True)
    parser.add_argument("--host", type=str, default="0.0.0.0")
    args = parser.parse_args()

    RESULTS_DIR = args.results_dir
    app.run(host=args.host, port=args.port, debug=False)
