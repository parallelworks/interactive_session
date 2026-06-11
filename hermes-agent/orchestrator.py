#!/usr/bin/env python3
"""Hermes ORCHESTRATOR -- coordinates worker agents across clusters.

Runs on the platform workspace. DISCOVERS its workers from the platform session
registry (`pw sessions ls`): every running `hermes-worker` session reports its
cluster (`targetName`) and port (`remotePort`). It then reaches each worker over
the hub-and-spoke transport `pw ssh <cluster> curl localhost:<port>/task` and
aggregates the answers. No static roster required.

Endpoints
  GET  /  (+ any prefix)   -> browser chat UI (pick workers from a live list)
  GET  /health             -> {"status":"ok","role":"orchestrator"}
  GET  /workers            -> {"workers":[{"cluster","port","session"}, ...]}  (discovered)
  POST /run                -> {"goal":..,"results":[...]}  delegate + aggregate
        body: {"goal":..., "targets":[{"cluster","port"}]}  (or {"workers":[names]}; else all)
"""
import argparse
import base64
import json
import os
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROLE = "orchestrator"
DEFAULT_PORT = os.environ.get("HERMES_AGENT_PORT", "8717")
DISPATCH_TIMEOUT = int(os.environ.get("HERMES_DISPATCH_TIMEOUT", "1800"))
LOCAL_TEST = os.environ.get("HERMES_LOCAL_TEST") == "1"  # reach localhost, skip pw ssh
WORKER_WORKFLOW = os.environ.get("HERMES_WORKER_WORKFLOW", "hermes-worker")


def discover_workers():
    """Find running hermes-worker sessions from the platform session registry."""
    try:
        out = subprocess.run(["pw", "sessions", "ls", "-o", "json"],
                             capture_output=True, text=True, timeout=30)
        data = json.loads(out.stdout or "[]")
    except Exception:
        return []
    rows = data if isinstance(data, list) else data.get("sessions", data.get("data", []))
    seen, workers = set(), []
    for s in rows:
        wr = s.get("workflowRun") or {}
        if wr.get("name") != WORKER_WORKFLOW or s.get("status") != "running":
            continue
        cluster = (s.get("targetName") or "").split("/")[-1]
        if not cluster or cluster in seen:
            continue
        seen.add(cluster)
        workers.append({"cluster": cluster,
                        "port": s.get("remotePort") or int(DEFAULT_PORT),
                        "session": s.get("name")})
    return workers


def delegate(cluster, task, port, context=""):
    payload = json.dumps({"task": task, "context": context})
    b64 = base64.b64encode(payload.encode()).decode()
    remote = ("echo {b} | base64 -d | "
              "curl -s -m {to} -X POST -H 'Content-Type: application/json' "
              "--data-binary @- http://localhost:{port}/task"
              ).format(b=b64, to=DISPATCH_TIMEOUT, port=port)
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


def run_goal(goal, targets=None):
    """Delegate `goal` to each target {cluster,port} and aggregate.

    targets=None -> discover and use all running workers.
    Integration point: a Hermes COORDINATOR could decide who does what here;
    v1 broadcasts to every target. https://hermes-agent.ai/features/multi-agent
    """
    if targets is None:
        targets = discover_workers()
    results = [delegate(t["cluster"], goal, t.get("port", DEFAULT_PORT)) for t in targets]
    return {"goal": goal, "workers": [t["cluster"] for t in targets], "results": results}


PAGE = """<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Hermes orchestrator</title><style>
body{font:15px/1.5 system-ui,sans-serif;margin:0;background:#f4f1ea;color:#222}
header{padding:10px 16px;background:#1f2d3d;color:#eee}
header b{color:#fff}
#workers{max-width:900px;margin:8px auto;padding:0 16px}
#workers label{display:inline-block;margin:4px 10px 4px 0;padding:4px 10px;background:#fff;border:1px solid #ddd;border-radius:14px;cursor:pointer}
#log{padding:16px;max-width:900px;margin:0 auto}
.msg{margin:10px 0;padding:10px 14px;border-radius:10px;white-space:pre-wrap}
.u{background:#dfe7f5} .a{background:#fff;border:1px solid #e3ddcf}
.role{font-size:11px;text-transform:uppercase;letter-spacing:.05em;opacity:.6;margin-bottom:3px}
.cl{font-weight:600;margin-top:8px}
#bar{position:sticky;bottom:0;background:#f4f1ea;padding:12px 16px;border-top:1px solid #ddd}
#bar div{max-width:900px;margin:0 auto;display:flex;gap:8px}
#q{flex:1;padding:10px;border:1px solid #bbb;border-radius:8px;font:inherit}
button{padding:10px 18px;border:0;border-radius:8px;background:#2f6fb5;color:#fff;cursor:pointer}
button:disabled{opacity:.5} #refresh{background:#888}
</style></head><body>
<header><b>Hermes orchestrator</b></header>
<div id="workers">workers: <span id="wlist">discovering…</span> <button id="refresh" onclick="loadWorkers()">refresh</button></div>
<div id="log"></div>
<div id="bar"><div>
  <input id="q" placeholder="Goal for the selected workers (e.g. tell me your hostname)" autofocus>
  <button id="send" onclick="ask()">Send</button>
</div></div>
<script>
const base=location.pathname.replace(/\\/+$/,'');
const wlist=document.getElementById('wlist'), log=document.getElementById('log'),
      q=document.getElementById('q'), btn=document.getElementById('send');
let WORKERS=[];
function esc(s){return (s||'').replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));}
async function loadWorkers(){
  wlist.textContent='discovering…';
  try{
    const d=await (await fetch(base+'/workers')).json();
    WORKERS=d.workers||[];
    if(!WORKERS.length){ wlist.textContent='none running — start a hermes-worker'; return; }
    wlist.innerHTML=WORKERS.map((w,i)=>'<label><input type="checkbox" data-i="'+i+'" checked> '+esc(w.cluster)+' <small>:'+w.port+'</small></label>').join('');
  }catch(e){ wlist.textContent='discovery error: '+esc(''+e); }
}
function selected(){
  return [...document.querySelectorAll('#wlist input:checked')].map(c=>WORKERS[+c.dataset.i]);
}
function add(cls,html){const m=document.createElement('div');m.className='msg '+cls;m.innerHTML=html;
  log.appendChild(m);window.scrollTo(0,document.body.scrollHeight);return m;}
async function ask(){
  const t=q.value.trim(); if(!t) return;
  const targets=selected();
  if(!targets.length){ add('a','<div class="role">orchestrator</div>Select at least one worker.'); return; }
  q.value=''; btn.disabled=true;
  add('u','<div class="role">goal &rarr; '+targets.map(w=>esc(w.cluster)).join(', ')+'</div>'+esc(t));
  const box=add('a','<div class="role">orchestrator</div>delegating…');
  try{
    const d=await (await fetch(base+'/run',{method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({goal:t, targets:targets})})).json();
    let html='<div class="role">orchestrator</div>';
    for(const x of (d.results||[])){
      const ans=(x.result && x.result.result)?x.result.result:(x.error||JSON.stringify(x.result));
      html+='<div class="cl">'+esc(x.cluster)+(x.ok?'':' (error)')+'</div>'+esc(ans);
    }
    box.innerHTML=html;
  }catch(e){ box.innerHTML='<div class="role">orchestrator</div>error: '+esc(''+e); }
  btn.disabled=false; q.focus();
}
q.addEventListener('keydown',e=>{if(e.key==='Enter')ask();});
loadWorkers();
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
        p = self.path.rstrip("/")
        if p.endswith("/health") or self.path == "/health":
            self._json(200, {"status": "ok", "role": ROLE})
        elif p.endswith("/workers") or self.path == "/workers":
            self._json(200, {"workers": discover_workers()})
        else:
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
            targets = req.get("targets")
            if targets is None and req.get("workers"):          # names -> look up ports
                disc = {w["cluster"]: w for w in discover_workers()}
                targets = [{"cluster": c, "port": disc.get(c, {}).get("port", int(DEFAULT_PORT))}
                           for c in req["workers"]]
            self._json(200, run_goal(req.get("goal", ""), targets))
        except Exception as e:  # noqa: BLE001
            self._json(500, {"error": str(e)})

    def log_message(self, *a):
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=int(os.environ.get("service_port", "8717")))
    ap.add_argument("--host", default="0.0.0.0")
    args = ap.parse_args()
    print("hermes orchestrator on {}:{} (workers auto-discovered)".format(args.host, args.port), flush=True)
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
