#!/usr/bin/env bash
#
# run.sh - Compute a Mandelbrot fractal, one row at a time.
#
# This is the "job" of the example. On a PBS or SLURM cluster a wrapper runs
# this script on a compute node. It writes its progress (a status file and a
# progressively-rendered image) into a shared work directory that server.sh
# reads to display live progress.
#
# Inputs (all passed as environment variables, so a wrapper can set them):
#   RESOLUTION=N   image width and height in pixels (default 1000). This is the
#                  runtime knob: the work grows with the square of the resolution,
#                  so 1400 takes about twice as long as 1000.
#   MAX_ITER=N     fractal detail / work per pixel (default 200).
#   WORK_DIR=path  shared folder for the output (default ./output next to this).
#
# Example:
#   RESOLUTION=1500 ./run.sh
#
set -euo pipefail

# Resolve where this script lives so the work directory is the same no matter
# which directory the job is launched from (compute nodes often start in $HOME).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Inputs arrive as environment variables (a wrapper sets them); fall back to
# sensible defaults when the script is run by hand.
RESOLUTION="${RESOLUTION:-1000}"
MAX_ITER="${MAX_ITER:-200}"

# Shared work directory. Override WORK_DIR to point at cluster scratch storage
# that both the compute node and the server can see.
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/output}"
mkdir -p "$WORK_DIR"

# Validate inputs up front so a typo gives a clear message, not a traceback.
check_positive_int() {  # name value
  if ! [[ "$2" =~ ^[0-9]+$ ]] || [ "$2" -lt 1 ]; then
    echo "ERROR: $1 must be a positive whole number (got '$2')." >&2
    echo "Set it like: RESOLUTION=1500 ./run.sh" >&2
    exit 1
  fi
}
check_positive_int "RESOLUTION" "$RESOLUTION"
check_positive_int "MAX_ITER" "$MAX_ITER"

# Use the Python environment created by install.sh.
PW_SOFTWARE="${PW_SOFTWARE:-$HOME/pw/software}"
PYTHON="$PW_SOFTWARE/fractal-demo/bin/python"
if [ ! -x "$PYTHON" ]; then
  echo "ERROR: Python environment not found at $PYTHON" >&2
  echo "Run ./install.sh first to create it." >&2
  exit 1
fi

echo "Computing a ${RESOLUTION}x${RESOLUTION} Mandelbrot fractal (max_iter=${MAX_ITER})."
echo "Work directory: $WORK_DIR"
echo "Start ./server.sh in another terminal to watch it render."
echo

export WORK_DIR MAX_ITER RESOLUTION

# The whole computation lives in this Python program. It uses only the Python
# standard library, so there is nothing to install and it runs offline.
"$PYTHON" - <<'PYTHON'
import json
import os
import struct
import time
import zlib

# ---- Inputs (all read from environment variables) ---------------------------
resolution = max(16, int(os.environ.get("RESOLUTION", "1000")))   # clamp so the image is never degenerate
max_iter = max(1, int(os.environ.get("MAX_ITER", "200")))
work_dir = os.environ.get("WORK_DIR", os.path.join(os.getcwd(), "output"))
os.makedirs(work_dir, exist_ok=True)

width = height = resolution
png_path = os.path.join(work_dir, "fractal.png")
status_path = os.path.join(work_dir, "status.json")

# The region of the complex plane we are drawing (the classic full view).
X_MIN, X_MAX = -2.0, 1.0
Y_MIN, Y_MAX = -1.5, 1.5

# The image is one flat array of bytes: 3 (R, G, B) per pixel. It starts black
# and fills in row by row, so a partial image shows how far the job has gotten.
pixels = bytearray(width * height * 3)

start = time.time()
update_every = max(1, height // 40)   # refresh the image ~40 times during the run


def mandelbrot(cx, cy):
    """Return how many steps the point (cx, cy) takes to escape, up to max_iter."""
    zx = zy = 0.0
    for i in range(max_iter):
        zx2, zy2 = zx * zx, zy * zy
        if zx2 + zy2 > 4.0:
            return i
        zy = 2.0 * zx * zy + cy
        zx = zx2 - zy2 + cx
    return max_iter


def color(i):
    """Turn an escape count into a smooth (R, G, B) color. Inside the set = black."""
    if i >= max_iter:
        return 0, 0, 0
    t = i / max_iter
    r = int(9 * (1 - t) * t * t * t * 255)
    g = int(15 * (1 - t) * (1 - t) * t * t * 255)
    b = int(8.5 * (1 - t) * (1 - t) * (1 - t) * t * 255)
    return min(255, r), min(255, g), min(255, b)


def write_png():
    """Write `pixels` to `png_path` as a PNG using only the standard library."""
    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data +
                struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))

    # Each row of a PNG is prefixed with a filter byte (0 = no filtering).
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw += pixels[y * width * 3:(y + 1) * width * 3]

    # Compression level 1 is fast (the image is rewritten many times) and the
    # large black areas of the fractal still compress very well.
    data = (b"\x89PNG\r\n\x1a\n" +
            chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(bytes(raw), 1)) +
            chunk(b"IEND", b""))

    # Write to a temp file and rename so the server never reads a half-done image.
    tmp = png_path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, png_path)


def write_status(rows_done, state):
    """Record progress so the server can show it."""
    status = {
        "state": state,                                  # "running" or "done"
        "rows_done": rows_done,
        "rows_total": height,
        "percent": round(100.0 * rows_done / height, 1),
        "resolution": resolution,
        "max_iter": max_iter,
        "elapsed_seconds": round(time.time() - start, 1),
    }
    tmp = status_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(status, f)
    os.replace(tmp, status_path)


# ---- Render -----------------------------------------------------------------
write_status(0, "running")   # publish a fresh 0% so the page drops any old result
write_png()

for row in range(height):
    cy = Y_MIN + (Y_MAX - Y_MIN) * row / (height - 1)
    for col in range(width):
        cx = X_MIN + (X_MAX - X_MIN) * col / (width - 1)
        r, g, b = color(mandelbrot(cx, cy))
        p = (row * width + col) * 3
        pixels[p], pixels[p + 1], pixels[p + 2] = r, g, b

    # Publish progress periodically, and always on the final row.
    if (row + 1) % update_every == 0 or row == height - 1:
        write_png()
        write_status(row + 1, "running")
        print("  row %d/%d (%.0f%%)" % (row + 1, height, 100.0 * (row + 1) / height))

write_status(height, "done")
print("Done in %.1fs -> %s" % (time.time() - start, png_path))
PYTHON

echo
echo "Finished. Image saved to: $WORK_DIR/fractal.png"
