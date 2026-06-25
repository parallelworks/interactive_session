#!/usr/bin/env bash
#
# server.sh - Serve a small web page that shows the fractal rendering live.
#
# Run this on a node that shares a filesystem with the job (for example the
# controller/login node). It writes a self-contained index.html into the work
# directory and serves that directory over HTTP. The page polls status.json and
# reloads fractal.png so you can watch the job progress.
#
# Usage:
#   ./server.sh [PORT]          (default port 8000, or set PORT)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/output}"
PORT="${1:-${PORT:-8000}}"

mkdir -p "$WORK_DIR"

# Use the Python environment created by install.sh.
PW_SOFTWARE="${PW_SOFTWARE:-$HOME/pw/software}"
PYTHON="$PW_SOFTWARE/fractal-demo/bin/python"
if [ ! -x "$PYTHON" ]; then
  echo "ERROR: Python environment not found at $PYTHON" >&2
  echo "Run ./install.sh first to create it." >&2
  exit 1
fi

# A placeholder status so the page works even before the job has started.
if [ ! -f "$WORK_DIR/status.json" ]; then
  echo '{"state":"waiting","rows_done":0,"rows_total":1,"percent":0,"resolution":0,"max_iter":0,"elapsed_seconds":0}' \
    > "$WORK_DIR/status.json"
fi

# Write the progress page. The quoted 'HTML' marker means nothing here is
# expanded by the shell, so the JavaScript is written exactly as-is.
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
  <div id="meta">Waiting for the job to start&hellip;</div>
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
          // no job has written progress yet
          document.getElementById('meta').textContent = 'Waiting for the job to start…';
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

# Fail early with a clear message if something is already on this port.
if ! "$PYTHON" -c "import socket,sys; s=socket.socket(); r=s.connect_ex(('127.0.0.1', $PORT)); s.close(); sys.exit(0 if r!=0 else 1)"; then
  echo "ERROR: Port $PORT is already in use." >&2
  echo "Stop the other server, or choose another port:  ./server.sh 8090" >&2
  exit 1
fi

# Print friendly URLs, then serve the work directory.
HOST="$(hostname -f 2>/dev/null || hostname)"
echo "Serving progress page from: $WORK_DIR"
echo "Open one of these in your browser:"
echo "    http://localhost:${PORT}/"
echo "    http://${HOST}:${PORT}/"
echo "Press Ctrl+C to stop."
echo

# http.server listens on all interfaces by default. cd first so it works on
# older Python versions that lack the --directory option.
cd "$WORK_DIR"
exec "$PYTHON" -m http.server "$PORT"
