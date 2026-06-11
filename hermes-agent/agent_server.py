#!/usr/bin/env python3
"""Hermes WORKER agent -- HTTP front-end for a per-cluster agent.

Exposes the agent over one HTTP port so the orchestrator (on the platform
workspace) can reach it via `pw ssh <cluster> curl localhost:<port>`.

Brain = the platform's OpenAI-compatible endpoint. Auth is the runtime
PW_API_KEY (never written to disk); org-provider models also require the
X-Allocation header. The worker runs a minimal real agent loop (a `run_shell`
tool) so it can actually act on the cluster -- e.g. report its own hostname.
If a `hermes` binary is present it is used instead (preferred path).

Endpoints
  GET  /  and  /health   -> {"status":"ok",...}
  POST /task             -> {"result":"..."}   run one task on this cluster
"""
import argparse
import json
import os
import shutil
import subprocess
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROLE = "worker"
CLUSTER = os.environ.get("HERMES_CLUSTER") or os.environ.get("PW_USER") or "unknown"
TASK_TIMEOUT = int(os.environ.get("HERMES_TASK_TIMEOUT", "1800"))

# --- brain config (platform OpenAI-compatible endpoint) -----------------------
BASE = os.environ.get("OPENAI_BASE_URL", "").rstrip("/")
API_KEY = os.environ.get("OPENAI_API_KEY", "")          # = PW_API_KEY at runtime
ALLOCATION = os.environ.get("X_ALLOCATION", "")          # org-provider requirement
MODEL = os.environ.get("MODEL", "org:glm/glm-5.1")
HERMES_TASK_CMD = os.environ.get("HERMES_TASK_CMD", "")  # override for a real hermes

TOOLS = [{
    "type": "function",
    "function": {
        "name": "run_shell",
        "description": "Run a shell command on THIS machine and return its stdout.",
        "parameters": {"type": "object",
                       "properties": {"command": {"type": "string"}},
                       "required": ["command"]},
    },
}]


def _run_shell(command):
    out = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=60)
    return (out.stdout or out.stderr).strip()


def _brain(messages):
    body = {"model": MODEL, "messages": messages, "tools": TOOLS, "tool_choice": "auto"}
    headers = {"Authorization": "Bearer " + API_KEY, "Content-Type": "application/json"}
    if ALLOCATION:
        headers["X-Allocation"] = ALLOCATION
    req = urllib.request.Request(BASE + "/chat/completions",
                                 data=json.dumps(body).encode(), headers=headers)
    with urllib.request.urlopen(req, timeout=TASK_TIMEOUT) as r:
        return json.load(r)["choices"][0]["message"]


def _agent_loop(task, context="", max_steps=4):
    """Minimal real agent: let the brain call run_shell, execute, feed back."""
    messages = [
        {"role": "system", "content": "You are an agent running on a compute cluster "
         "named '{}'. When asked about this machine, use run_shell to find out for "
         "real.".format(CLUSTER)},
        {"role": "user", "content": task if not context else context + "\n\n" + task},
    ]
    for _ in range(max_steps):
        msg = _brain(messages)
        messages.append({k: v for k, v in msg.items() if v is not None})
        calls = msg.get("tool_calls") or []
        if not calls:
            return msg.get("content", "")
        for tc in calls:
            args = json.loads(tc["function"].get("arguments") or "{}")
            messages.append({"role": "tool", "tool_call_id": tc["id"],
                             "content": _run_shell(args.get("command", ""))})
    return "(max steps reached)"


def run_hermes_task(task, context=""):
    prompt = task if not context else "{}\n\n{}".format(context, task)
    if HERMES_TASK_CMD:                                  # explicit hermes command
        out = subprocess.run(HERMES_TASK_CMD.format(task=prompt), shell=True,
                             capture_output=True, text=True, timeout=TASK_TIMEOUT)
        return (out.stdout or out.stderr).strip()
    if shutil.which("hermes"):                           # preferred: real hermes
        # TODO confirm headless flag + that hermes can send the X-Allocation header
        out = subprocess.run(["hermes", "run", "--prompt", prompt],
                             capture_output=True, text=True, timeout=TASK_TIMEOUT)
        return (out.stdout or out.stderr).strip()
    if BASE and API_KEY:                                 # built-in minimal agent
        return _agent_loop(task, context)
    return "[stub:{}] no brain configured: {}".format(CLUSTER, prompt[:200])
# ------------------------------------------------------------------------------

# Minimal chat UI served at the session root so the worker is usable in the
# browser. Paths are matched by suffix (do_GET/do_POST) so it works whether the
# platform forwards "/task" or the full "<session-prefix>/task".
PAGE = """<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Hermes worker</title><style>
body{font:15px/1.5 system-ui,sans-serif;margin:0;background:#f4f1ea;color:#222}
header{padding:10px 16px;background:#2b2b2b;color:#eee}
header b{color:#fff} header span{opacity:.7;font-size:13px}
#log{padding:16px;max-width:820px;margin:0 auto}
.msg{margin:10px 0;padding:10px 14px;border-radius:10px;white-space:pre-wrap}
.u{background:#dfe7f5;align-self:end} .a{background:#fff;border:1px solid #e3ddcf}
.role{font-size:11px;text-transform:uppercase;letter-spacing:.05em;opacity:.6;margin-bottom:3px}
#bar{position:sticky;bottom:0;background:#f4f1ea;padding:12px 16px;border-top:1px solid #ddd}
#bar div{max-width:820px;margin:0 auto;display:flex;gap:8px}
#q{flex:1;padding:10px;border:1px solid #bbb;border-radius:8px;font:inherit}
button{padding:10px 18px;border:0;border-radius:8px;background:#b5562f;color:#fff;cursor:pointer}
button:disabled{opacity:.5}
</style></head><body>
<header><b>Hermes worker</b> &mdash; <span id="meta">connecting…</span></header>
<div id="log"></div>
<div id="bar"><div>
  <input id="q" placeholder="Ask the agent (e.g. tell me your hostname)" autofocus>
  <button id="send" onclick="ask()">Send</button>
</div></div>
<script>
const base = location.pathname.replace(/\\/+$/,'');
const log = document.getElementById('log'), q = document.getElementById('q'), btn = document.getElementById('send');
fetch(base + '/health').then(r=>r.json()).then(d=>{
  document.getElementById('meta').textContent =
    'cluster: ' + d.cluster + '  ·  model: ' + d.model + '  ·  brain: ' + d.brain;
}).catch(()=>{});
function add(role, text){
  const m = document.createElement('div');
  m.className = 'msg ' + (role==='you'?'u':'a');
  m.innerHTML = '<div class="role">'+role+'</div>';
  m.appendChild(document.createTextNode(text));
  log.appendChild(m); window.scrollTo(0, document.body.scrollHeight);
  return m;
}
async function ask(){
  const t = q.value.trim(); if(!t) return;
  q.value=''; btn.disabled=true; add('you', t);
  const thinking = add('agent', '…');
  try{
    const r = await fetch(base + '/task', {method:'POST',
      headers:{'Content-Type':'application/json'}, body: JSON.stringify({task:t})});
    const d = await r.json();
    thinking.lastChild.textContent = d.result || d.error || JSON.stringify(d);
  }catch(e){ thinking.lastChild.textContent = 'error: ' + e; }
  btn.disabled=false; q.focus();
}
q.addEventListener('keydown', e=>{ if(e.key==='Enter') ask(); });
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.rstrip("/").endswith("/health") or self.path == "/health":
            self._send(200, {"status": "ok", "role": ROLE, "cluster": CLUSTER,
                             "brain": bool(BASE and API_KEY), "model": MODEL})
            return
        body = PAGE.encode()              # chat UI at the session root (any prefix)
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if not self.path.rstrip("/").endswith("/task") and self.path != "/task":
            self._send(404, {"error": "not found"})
            return
        try:
            n = int(self.headers.get("Content-Length", 0))
            req = json.loads(self.rfile.read(n) or b"{}")
            result = run_hermes_task(req.get("task", ""), req.get("context", ""))
            self._send(200, {"cluster": CLUSTER, "result": result})
        except Exception as e:  # noqa: BLE001 - surface failures to the caller
            self._send(500, {"cluster": CLUSTER, "error": str(e)})

    def log_message(self, *a):
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=int(os.environ.get("service_port", "8717")))
    ap.add_argument("--host", default="0.0.0.0")
    args = ap.parse_args()
    print("hermes worker [{}] on {}:{} | brain={} model={}".format(
        CLUSTER, args.host, args.port, bool(BASE and API_KEY), MODEL), flush=True)
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
