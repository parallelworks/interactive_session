#!/usr/bin/env python3
"""Progressive Mandelbrot renderer with a live web progress page.

Pure standard library (no pip installs): http.server + threading + zlib.
A background thread renders the Mandelbrot set row by row; the HTTP server
serves a self-refreshing HTML page, the in-progress PNG, and a JSON status.

Endpoints:
  GET /            -> HTML progress page (auto-refreshes)
  GET /fractal.png -> current PNG (rows not yet computed are black)
  GET /status      -> JSON {progress, rows_done, height, max_iter, done, elapsed}
  GET /healthz     -> "ok"  (used to confirm the server is up)
"""
import argparse
import json
import os
import struct
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = {
    "rows_done": 0,
    "height": 0,
    "width": 0,
    "max_iter": 0,
    "done": False,
    "started": time.time(),
    "png": b"",
}
LOCK = threading.Lock()


def write_png(width, height, rgb):
    """Encode an RGB (3 bytes/pixel) buffer as a PNG using only zlib."""
    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    raw = bytearray()
    stride = width * 3
    for y in range(height):
        raw.append(0)  # filter type 0 (None) for this scanline
        raw.extend(rgb[y * stride:(y + 1) * stride])
    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)  # 8-bit RGB
    idat = zlib.compress(bytes(raw), 6)
    return sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")


def color(n, max_iter):
    """Map an escape iteration count to an RGB triple (smooth-ish palette)."""
    if n >= max_iter:
        return (0, 0, 0)
    t = n / max_iter
    r = int(9 * (1 - t) * t * t * t * 255)
    g = int(15 * (1 - t) * (1 - t) * t * t * 255)
    b = int(8.5 * (1 - t) * (1 - t) * (1 - t) * t * 255)
    return (r & 255, g & 255, b & 255)


def render(width, height, max_iter, out_dir):
    """Render the Mandelbrot set row by row, updating shared STATE as it goes."""
    xmin, xmax, ymin, ymax = -2.5, 1.0, -1.25, 1.25
    rgb = bytearray(width * height * 3)  # starts all-black
    with LOCK:
        STATE.update(width=width, height=height, max_iter=max_iter,
                     rows_done=0, done=False, started=time.time())
        STATE["png"] = write_png(width, height, rgb)

    for py in range(height):
        y0 = ymin + (ymax - ymin) * py / height
        for px in range(width):
            x0 = xmin + (xmax - xmin) * px / width
            x = y = 0.0
            n = 0
            while x * x + y * y <= 4.0 and n < max_iter:
                x, y = x * x - y * y + x0, 2.0 * x * y + y0
                n += 1
            r, g, b = color(n, max_iter)
            off = (py * width + px) * 3
            rgb[off] = r
            rgb[off + 1] = g
            rgb[off + 2] = b
        # Publish a fresh PNG every few rows so the page shows progress.
        if py % 8 == 0 or py == height - 1:
            png = write_png(width, height, rgb)
            with LOCK:
                STATE["rows_done"] = py + 1
                STATE["png"] = png

    png = write_png(width, height, rgb)
    with LOCK:
        STATE["rows_done"] = height
        STATE["done"] = True
        STATE["png"] = png
    try:
        with open(os.path.join(out_dir, "fractal.png"), "wb") as fh:
            fh.write(png)
    except OSError:
        pass


PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>Mandelbrot — live render</title>
<style>
 body{font-family:system-ui,sans-serif;background:#0b0b12;color:#e8e8f0;text-align:center;margin:0;padding:24px}
 h1{font-weight:600;letter-spacing:.5px}
 #bar{width:480px;max-width:90%;height:14px;border:1px solid #444;border-radius:7px;margin:12px auto;overflow:hidden;background:#1a1a26}
 #fill{height:100%;width:0;background:linear-gradient(90deg,#5b8cff,#c45bff);transition:width .3s}
 img{margin-top:14px;border:1px solid #333;border-radius:6px;max-width:92%}
 .muted{color:#9a9ab0;font-size:14px}
</style></head>
<body>
 <h1>Mandelbrot set — progressive render</h1>
 <div id="bar"><div id="fill"></div></div>
 <div id="pct" class="muted">starting…</div>
 <div><img id="img" src="fractal.png" alt="fractal"></div>
 <div class="muted" id="meta"></div>
<script>
async function tick(){
  try{
    const s = await (await fetch('status',{cache:'no-store'})).json();
    document.getElementById('fill').style.width = (s.progress*100).toFixed(1)+'%';
    document.getElementById('pct').textContent =
      s.done ? 'done — '+s.elapsed.toFixed(1)+'s' : (s.progress*100).toFixed(1)+'%  ('+s.rows_done+'/'+s.height+' rows)';
    document.getElementById('meta').textContent =
      s.width+'x'+s.height+'  max_iter='+s.max_iter;
    document.getElementById('img').src = 'fractal.png?t=' + Date.now();
    if(!s.done) setTimeout(tick, 700); else setTimeout(tick, 3000);
  }catch(e){ setTimeout(tick, 1500); }
}
tick();
</script>
</body></html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):  # quieter logs
        pass

    def _send(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            self._send(200, "text/html; charset=utf-8", PAGE.encode())
        elif path == "/fractal.png":
            with LOCK:
                png = STATE["png"]
            self._send(200, "image/png", png)
        elif path == "/status":
            with LOCK:
                done = STATE["done"]
                rows = STATE["rows_done"]
                h = STATE["height"] or 1
                body = json.dumps({
                    "progress": rows / h,
                    "rows_done": rows,
                    "height": STATE["height"],
                    "width": STATE["width"],
                    "max_iter": STATE["max_iter"],
                    "done": done,
                    "elapsed": time.time() - STATE["started"],
                }).encode()
            self._send(200, "application/json", body)
        elif path == "/healthz":
            self._send(200, "text/plain", b"ok")
        else:
            self._send(404, "text/plain", b"not found")

    do_HEAD = do_GET


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--width", type=int, default=480)
    ap.add_argument("--height", type=int, default=320)
    ap.add_argument("--max-iter", type=int, default=200)
    ap.add_argument("--out-dir", default=".")
    args = ap.parse_args()

    t = threading.Thread(target=render,
                         args=(args.width, args.height, args.max_iter, args.out_dir),
                         daemon=True)
    t.start()

    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    print("Mandelbrot server listening on %s:%d (%dx%d, max_iter=%d)"
          % (args.host, args.port, args.width, args.height, args.max_iter), flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
