#!/usr/bin/env bash
#
# run.sh - Render a Mandelbrot fractal and serve a live progress page.
#
# This is the whole job. It starts a small web server that shows the rendering
# as it happens, then computes the fractal row by row, writing its progress
# (a status file and the image) into the folder the server reads from. When the
# render finishes it keeps serving so the result stays viewable.
#
# Inputs (all passed as environment variables, so a wrapper can set them):
#   RESOLUTION=N   image width and height in pixels (default 1000). This is the
#                  runtime knob: the work grows with the square of the resolution.
#   PORT=N         port the progress page is served on (default 8000).
#   MAX_ITER=N     fractal detail / work per pixel (default 200).
#   WORK_DIR=path  folder for the output (default ./output next to this script).
#
# Example:
#   RESOLUTION=1500 PORT=8000 ./run.sh
#
set -euo pipefail

# Resolve where this script lives so the work directory is the same no matter
# which directory the job is launched from (compute nodes often start in $HOME).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Inputs arrive as environment variables; fall back to defaults for manual runs.
RESOLUTION="${RESOLUTION:-1000}"
PORT="${PORT:-8000}"
MAX_ITER="${MAX_ITER:-200}"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/output}"
mkdir -p "$WORK_DIR"

# Validate inputs up front so a typo gives a clear message, not a traceback.
check_positive_int() {  # name value
  if ! [[ "$2" =~ ^[0-9]+$ ]] || [ "$2" -lt 1 ]; then
    echo "ERROR: $1 must be a positive whole number (got '$2')." >&2
    echo "Set it like: RESOLUTION=1500 PORT=8000 ./run.sh" >&2
    exit 1
  fi
}
check_positive_int "RESOLUTION" "$RESOLUTION"
check_positive_int "PORT" "$PORT"
check_positive_int "MAX_ITER" "$MAX_ITER"

# Use the Python environment created by install.sh.
PW_SOFTWARE="${PW_SOFTWARE:-$HOME/pw/software}"
PYTHON="$PW_SOFTWARE/fractal-demo/bin/python"
if [ ! -x "$PYTHON" ]; then
  echo "ERROR: Python environment not found at $PYTHON" >&2
  echo "Run ./install.sh first to create it." >&2
  exit 1
fi

# Write the progress page into the work directory. The quoted 'HTML' marker
# means nothing here is expanded by the shell, so the JavaScript is left as-is.
cat > "$WORK_DIR/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Fractal Progress</title>
  <style>
    body { background:#0d1117; color:#e6edf3; font-family:system-ui,sans-serif;
           margin:0; padding:2rem; text-align:center; }
    h1 { font-weight:600; margin:0 0 1rem; }
    #meta { font-family:ui-monospace,monospace; color:#8b949e; margin-bottom:1rem; }
    .bar { width:min(90vw,640px); height:14px; margin:0 auto 1.5rem;
           background:#21262d; border-radius:7px; overflow:hidden; }
    #fill { height:100%; width:0; background:linear-gradient(90deg,#1f6feb,#a371f7);
            transition:width .3s ease; }
    img { width:min(90vw,640px); image-rendering:pixelated;
          border:1px solid #30363d; border-radius:8px; background:#000; }
  </style>
</head>
<body>
  <h1>Mandelbrot Fractal</h1>
  <div id="meta">Waiting for the render to start&hellip;</div>
  <div class="bar"><div id="fill"></div></div>
  <img id="img" src="fractal.png" alt="fractal render">
  <script>
    async function tick() {
      try {
        const status = await (await fetch('status.json?t=' + Date.now())).json();
        document.getElementById('fill').style.width = status.percent + '%';
        if (status.state === 'running' || status.state === 'done') {
          document.getElementById('meta').textContent =
            status.state.toUpperCase() + ' — ' + status.percent + '%  (' +
            status.rows_done + '/' + status.rows_total + ' rows)   ' +
            status.resolution + '×' + status.resolution + ' px, ' +
            status.max_iter + ' iter, ' + status.elapsed_seconds + 's';
          document.getElementById('img').src = 'fractal.png?t=' + Date.now();
        } else {
          document.getElementById('meta').textContent = 'Waiting for the render to start…';
        }
        if (status.state === 'done') return;   // stop polling when finished
      } catch (e) { /* files not there yet; try again next tick */ }
      setTimeout(tick, 1000);
    }
    tick();
  </script>
</body>
</html>
HTML

# Start the web server in the background so the page is live while we render.
# It serves the work directory; cd first so it works on older Python versions.
( cd "$WORK_DIR" && exec "$PYTHON" -m http.server "$PORT" ) &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null' EXIT   # stop the server when this script ends

echo "Serving the progress page on port ${PORT}."
echo "Rendering a ${RESOLUTION}x${RESOLUTION} fractal (max_iter=${MAX_ITER})..."
echo

export WORK_DIR MAX_ITER RESOLUTION

# Compute the fractal. It writes status.json and fractal.png into WORK_DIR as it
# goes, which the page above polls and displays. Standard library only.
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
    """Record progress so the page can show it."""
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
print("Done in %.1fs" % (time.time() - start))
PYTHON

echo
echo "Render complete. Still serving on port ${PORT} — press Ctrl+C to stop."
wait "$SERVER_PID"   # keep serving so the finished image stays viewable
