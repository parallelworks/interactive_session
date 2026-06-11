#!/usr/bin/env python3
"""Hermes ORCHESTRATOR -- coordinates worker agents across clusters.

Runs on the platform workspace. Reaches each worker over the hub-and-spoke
transport `pw ssh <cluster> curl localhost:<agent_port>/task` (no inbound ports,
reuses pw auth) and aggregates the answers.

Endpoints
  GET  /  (+ any prefix)   -> browser chat UI
  GET  /health             -> {"status":"ok","workers":[...]}
  POST /run                -> {"goal":..., "workers":[...]}  delegate + aggregate
                              body may override the roster: {"goal":..,"workers":[..]}
"""
import argparse
import base64
import json
import os
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROLE = "orchestrator"
WORKERS = [c.strip() for c in os.environ.get("HERMES_WORKERS", "").split(",") if c.strip()]
AGENT_PORT = os.environ.get("HERMES_AGENT_PORT", "8717")
DISPATCH_TIMEOUT = int(os.environ.get("HERMES_DISPATCH_TIMEOUT", "1800"))
LOCAL_TEST = os.environ.get("HERMES_LOCAL_TEST") == "1"  # reach localhost, skip pw ssh


def delegate(cluster, task, context=""):
    payload = json.dumps({"task": task, "context": context})
    b64 = base64.b64encode(payload.encode()).decode()
    remote = ("echo {b} | base64 -d | "
              "curl -s -m {to} -X POST -H 'Content-Type: application/json' "
              "--data-binary @- http://localhost:{port}/task"
              ).format(b=b64, to=DISPATCH_TIMEOUT, port=AGENT_PORT)
    argv = ["bash", "-c", remote] if LOCAL_TEST else ["pw", "ssh", cluster, remote]
    try:
        out = subprocess.run(argv, capture_output=True, text=True,
                             timeout=DISPATCH_TIMEOUT + 60)
        body = (out.stdout or "").strip()
        try:
            body = json.loads(body)
        except Exception:
            pass
        return {"cluster": cluster, "ok": out.returncode == 0, "result": body,
                "stderr": (out.stderr or "").strip()[:500]}
    except Exception as e:  # noqa: BLE001
        return {"cluster": cluster, "ok": False, "error": str(e)}


def run_goal(goal, workers=None):
    """Delegate `goal` to each target cluster and aggregate.

    Integration point: hand `goal` to a Hermes COORDINATOR whose delegate tool
    calls delegate(cluster, task) -- the coordinator decides who does what.
    v1: broadcast to every target. https://hermes-agent.ai/features/multi-agent
    """
    targets = [w for w in (workers or WORKERS) if w]
    return {"goal": goal, "workers": targets,
            "results": [delegate(c, goal) for c in targets]}


PAGE = """<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Hermes orchestrator</title><style>
body{font:15px/1.5 system-ui,sans-serif;margin:0;background:#f4f1ea;color:#222}
header{padding:10px 16px;background:#1f2d3d;color:#eee}
header b{color:#fff} header span{opacity:.7;font-size:13px}
#log{padding:16px;max-width:900px;margin:0 auto}
.msg{margin:10px 0;padding:10px 14px;border-radius:10px;white-space:pre-wrap}
.u{background:#dfe7f5} .a{background:#fff;border:1px solid #e3ddcf}
.role{font-size:11px;text-transform:uppercase;letter-spacing:.05em;opacity:.6;margin-bottom:3px}
.cl{font-weight:600;margin-top:8px}
#bar{position:sticky;bottom:0;background:#f4f1ea;padding:12px 16px;border-top:1px solid #ddd}
#bar div{max-width:900px;margin:0 auto;display:flex;gap:8px;flex-wrap:wrap}
#q{flex:1;min-width:280px;padding:10px;border:1px solid #bbb;border-radius:8px;font:inherit}
#cl{width:240px;padding:10px;border:1px solid #bbb;border-radius:8px;font:inherit}
button{padding:10px 18px;border:0;border-radius:8px;background:#2f6fb5;color:#fff;cursor:pointer}
button:disabled{opacity:.5}
</style></head><body>
<header><b>Hermes orchestrator</b> &mdash; <span id="meta">connecting…</span></header>
<div id="log"></div>
<div id="bar"><div>
  <input id="q" placeholder="Goal to delegate (e.g. tell me your hostname)" autofocus>
  <input id="cl" placeholder="clusters (comma-sep)">
  <button id="send" onclick="ask()">Send</button>
</div></div>
<script>
const base = location.pathname.replace(/\\/+$/,'');
const log=document.getElementById('log'), q=document.getElementById('q'),
      cl=document.getElementById('cl'), btn=document.getElementById('send');
fetch(base+'/health').then(r=>r.json()).then(d=>{
  document.getElementById('meta').textContent='workers: '+((d.workers||[]).join(', ')||'(none configured — type clusters at right)');
  if((d.workers||[]).length) cl.value=d.workers.join(',');
}).catch(()=>{});
function add(cls,html){const m=document.createElement('div');m.className='msg '+cls;m.innerHTML=html;
  log.appendChild(m);window.scrollTo(0,document.body.scrollHeight);return m;}
function esc(s){return (s||'').replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));}
async function ask(){
  const t=q.value.trim(); if(!t) return;
  const workers=cl.value.split(',').map(s=>s.trim()).filter(Boolean);
  q.value=''; btn.disabled=true;
  add('u','<div class="role">goal</div>'+esc(t));
  const box=add('a','<div class="role">orchestrator</div>delegating…');
  try{
    const r=await fetch(base+'/run',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({goal:t, workers:workers})});
    const d=await r.json();
    let html='<div class="role">orchestrator</div>';
    if(!d.results || !d.results.length){ html+='No workers targeted. Enter cluster names on the right.'; }
    for(const x of (d.results||[])){
      const ans=(x.result && x.result.result) ? x.result.result : (x.error||JSON.stringify(x.result));
      html+='<div class="cl">'+esc(x.cluster)+(x.ok?'':' (error)')+'</div>'+esc(ans);
    }
    box.innerHTML=html;
  }catch(e){ box.innerHTML='<div class="role">orchestrator</div>error: '+esc(''+e); }
  btn.disabled=false; q.focus();
}
q.addEventListener('keydown',e=>{if(e.key==='Enter')ask();});
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.rstrip("/").endswith("/health") or self.path == "/health":
            self._json(200, {"status": "ok", "role": ROLE, "workers": WORKERS})
            return
        body = PAGE.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if not self.path.rstrip("/").endswith("/run") and self.path != "/run":
            self._json(404, {"error": "not found"})
            return
        try:
            n = int(self.headers.get("Content-Length", 0))
            req = json.loads(self.rfile.read(n) or b"{}")
            w = req.get("workers")
            if isinstance(w, str):
                w = [x.strip() for x in w.split(",") if x.strip()]
            self._json(200, run_goal(req.get("goal", ""), w))
        except Exception as e:  # noqa: BLE001
            self._json(500, {"error": str(e)})

    def log_message(self, *a):
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=int(os.environ.get("service_port", "8717")))
    ap.add_argument("--host", default="0.0.0.0")
    args = ap.parse_args()
    print("hermes orchestrator on {}:{} | workers={}".format(args.host, args.port, WORKERS), flush=True)
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
