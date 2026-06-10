#!/usr/bin/env python3
"""A live "training" dashboard served over HTTP (pure stdlib).

A background thread simulates a training run (loss decays with noise; accuracy
rises); the page polls /metrics and draws a live SVG loss curve. Counterpart to
the fractal demo: that renders an image server-side, this streams a numeric time
series and charts it client-side.

Endpoints:  /  (dashboard)   /metrics (JSON history)   /healthz
"""
import argparse
import json
import math
import random
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = {"history": [], "epochs": 0, "done": False, "started": time.time()}
LOCK = threading.Lock()


def train(epochs, period):
    rnd = random.Random(1)
    with LOCK:
        STATE.update(history=[], epochs=epochs, done=False, started=time.time())
    for e in range(1, epochs + 1):
        loss = 2.5 * math.exp(-e / (epochs / 4.0)) + rnd.uniform(0, 0.15)
        acc = max(0.0, min(1.0, 1.0 - loss / 3.0))
        with LOCK:
            STATE["history"].append({"epoch": e, "loss": round(loss, 4), "acc": round(acc, 4)})
        time.sleep(period)
    with LOCK:
        STATE["done"] = True


PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>trainwatch</title>
<style>
 body{font-family:system-ui,sans-serif;background:#0b0b12;color:#e8e8f0;margin:0;padding:24px;text-align:center}
 h1{font-weight:600} .stat{display:inline-block;margin:0 18px;font-size:15px;color:#cfcfe6}
 .stat b{display:block;font-size:26px;color:#fff} svg{background:#12121c;border:1px solid #333;border-radius:8px;margin-top:14px}
 .muted{color:#9a9ab0;font-size:13px}
</style></head><body>
 <h1>trainwatch &mdash; live training</h1>
 <div><span class="stat">epoch <b id="ep">0</b></span><span class="stat">loss <b id="loss">&mdash;</b></span>
 <span class="stat">acc <b id="acc">&mdash;</b></span><span class="stat">status <b id="st">starting</b></span></div>
 <svg id="chart" width="640" height="320" viewBox="0 0 640 320"></svg>
 <div class="muted" id="meta"></div>
<script>
const W=640,H=320,P=36;
function draw(hist){
 const svg=document.getElementById('chart');
 if(!hist.length){return}
 const xs=hist.map(d=>d.epoch), ys=hist.map(d=>d.loss);
 const xmax=Math.max(...xs,1), ymax=Math.max(...ys,0.1);
 const sx=e=>P+(W-2*P)*(e-1)/Math.max(xmax-1,1);
 const sy=v=>H-P-(H-2*P)*v/ymax;
 let pts=hist.map(d=>sx(d.epoch)+','+sy(d.loss)).join(' ');
 let grid='';
 for(let i=0;i<=4;i++){let y=P+(H-2*P)*i/4;grid+=`<line x1=${P} y1=${y} x2=${W-P} y2=${y} stroke=#2a2a3a/>`;}
 svg.innerHTML=grid+`<polyline points="${pts}" fill=none stroke=#5b8cff stroke-width=2.5/>`+
   `<text x=${P} y=20 fill=#9a9ab0 font-size=12>loss</text>`+
   `<text x=${W-P-40} y=${H-12} fill=#9a9ab0 font-size=12>epoch</text>`;
}
async function tick(){
 try{
  const s=await (await fetch('metrics',{cache:'no-store'})).json();
  const h=s.history; const last=h[h.length-1]||{};
  document.getElementById('ep').textContent=(last.epoch||0)+'/'+s.epochs;
  document.getElementById('loss').textContent=last.loss!=null?last.loss.toFixed(4):'—';
  document.getElementById('acc').textContent=last.acc!=null?(last.acc*100).toFixed(1)+'%':'—';
  document.getElementById('st').textContent=s.done?'done':'training';
  document.getElementById('meta').textContent='elapsed '+s.elapsed.toFixed(1)+'s';
  draw(h);
  setTimeout(tick, s.done?3000:500);
 }catch(e){setTimeout(tick,1500);}
}
tick();
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
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
        elif path == "/metrics":
            with LOCK:
                body = json.dumps({
                    "history": STATE["history"],
                    "epochs": STATE["epochs"],
                    "done": STATE["done"],
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
    ap.add_argument("--epochs", type=int, default=60)
    ap.add_argument("--period", type=float, default=0.5)
    a = ap.parse_args()
    threading.Thread(target=train, args=(a.epochs, a.period), daemon=True).start()
    srv = ThreadingHTTPServer((a.host, a.port), Handler)
    print("trainwatch on %s:%d (%d epochs)" % (a.host, a.port, a.epochs), flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
