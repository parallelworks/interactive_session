#!/usr/bin/env python3
"""LibreChat Service Manager — stdlib-only HTTP server."""

import json
import os
import subprocess
import threading
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

DATA_DIR = os.environ.get('DATA_DIR', '')
LIBRECHAT_PORT = os.environ.get('LIBRECHAT_PORT', '')
MGR_PORT = int(os.environ.get('MGR_PORT', '8080'))

PORTS = {
    'mongodb':    os.environ.get('MONGODB_PORT', ''),
    'meilisearch': os.environ.get('MEILI_PORT', ''),
    'pgvector':   os.environ.get('PG_PORT', ''),
    'ragapi':     os.environ.get('RAG_PORT', ''),
    'librechat':  LIBRECHAT_PORT,
}
LIBRECHAT_DIR = os.path.dirname(DATA_DIR) if DATA_DIR else ''
SERVICES = ['mongodb', 'meilisearch', 'pgvector', 'ragapi', 'librechat']


class JobStore:
    def __init__(self):
        self._lock = threading.Lock()
        self._jobs = {}

    def create(self, label=''):
        jid = uuid.uuid4().hex[:8]
        with self._lock:
            self._jobs[jid] = {'label': label, 'lines': [], 'done': False, 'success': None}
        return jid

    def append(self, jid, line):
        with self._lock:
            if jid in self._jobs:
                self._jobs[jid]['lines'].append(line)

    def finish(self, jid, success):
        with self._lock:
            if jid in self._jobs:
                self._jobs[jid]['done'] = True
                self._jobs[jid]['success'] = success

    def get(self, jid):
        with self._lock:
            j = self._jobs.get(jid)
            return dict(j) if j else None


_jobs = JobStore()


def _run_restart(jid, script_path):
    try:
        proc = subprocess.Popen(
            ['bash', script_path],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1,
        )
        for line in proc.stdout:
            _jobs.append(jid, line.rstrip())
        proc.wait()
        _jobs.finish(jid, proc.returncode == 0)
    except Exception as exc:
        _jobs.append(jid, f'ERROR: {exc}')
        _jobs.finish(jid, False)


def _get_status(svc):
    pid_path = os.path.join(DATA_DIR, 'pids', f'{svc}.pid')
    if not os.path.isfile(pid_path):
        return 'stopped'
    try:
        with open(pid_path) as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)
        return 'running'
    except Exception:
        return 'stopped'


def _tail_log(svc, n=100):
    log = os.path.join(DATA_DIR, 'logs', f'{svc}.log')
    if not os.path.isfile(log):
        return f'(no log file at {log})'
    r = subprocess.run(['tail', '-n', str(n), log], capture_output=True, text=True)
    return r.stdout or '(empty)'


# JavaScript served as an external file to avoid CSP inline-script restrictions.
JS_CODE = r"""
const SVCS=['mongodb','meilisearch','pgvector','ragapi','librechat'];
const LABELS={mongodb:'MongoDB',meilisearch:'MeiliSearch',pgvector:'PostgreSQL / pgvector',ragapi:'RAG API',librechat:'LibreChat'};
// Compute base URL once — strip trailing slash so we can always append /path.
// Works whether the session URL has a trailing slash or not.
const _BASE=window.location.href.split('?')[0].replace(/\/+$/,'').replace(/\/app\.js$/,'');
const api=p=>_BASE+'/'+p;
let status={},ports={},lcDir='',pollTimer=null,jobTimer=null,currentJob=null;

async function fetchStatus(){
  const url=api('status');
  try{
    const r=await fetch(url);
    if(!r.ok){appendCon('Status '+r.status+' from '+url);return;}
    const d=await r.json();
    status=d.status||{};ports=d.ports||{};lcDir=d.librechat_dir||'';
    document.getElementById('hdr-dir').textContent=lcDir?'Directory: '+lcDir:'';
    if(d.librechat_port){
      const el=document.getElementById('lc-link');
      el.textContent='LibreChat port: '+d.librechat_port;
      el.style.display='inline';
    }
    renderGrid();
  }catch(e){appendCon('Status error: '+e+' (url: '+url+')');}
}

function renderGrid(){
  const g=document.getElementById('grid');
  g.innerHTML=SVCS.map(s=>{
    const st=status[s]||'unknown';
    const port=ports[s]?'port '+ports[s]:'';
    return `<div class="card" id="card-${s}">
  <div class="card-head"><span class="dot ${st}" id="dot-${s}"></span><span class="card-name">${LABELS[s]}</span></div>
  <div class="card-port">${port}</div>
  <div class="card-btns">
    <button class="btn btn-primary" onclick="restart('${s}')">&#8635; Restart</button>
    <button class="btn btn-logs" onclick="showLogs('${s}')">Logs</button>
  </div>
</div>`;}).join('');
}

async function restart(svc){
  setConTitle('Restarting '+svc+'...');
  clearCon();
  document.querySelectorAll('.btn').forEach(b=>b.disabled=true);
  try{
    const r=await fetch(api('restart/'+svc),{method:'POST'});
    const d=await r.json();
    if(d.job_id){currentJob=d.job_id;pollJob();}
  }catch(e){appendCon('ERROR: '+e);enableBtns();}
}

async function restartAll(){
  setConTitle('Restarting all services...');
  clearCon();
  document.querySelectorAll('.btn').forEach(b=>b.disabled=true);
  try{
    const r=await fetch(api('restart/all'),{method:'POST'});
    const d=await r.json();
    if(d.job_id){currentJob=d.job_id;pollJob();}
  }catch(e){appendCon('ERROR: '+e);enableBtns();}
}

async function showLogs(svc){
  setConTitle('Logs: '+svc);
  clearCon();
  try{
    const r=await fetch(api('logs/'+svc));
    document.getElementById('con-out').textContent=await r.text();
    scrollCon();
  }catch(e){appendCon('ERROR: '+e);}
}

let lastLineCount=0;
async function pollJob(){
  if(!currentJob)return;
  try{
    const r=await fetch(api('job/'+currentJob));
    const d=await r.json();
    if(!d){enableBtns();return;}
    const lines=d.lines||[];
    if(lines.length>lastLineCount){
      for(let i=lastLineCount;i<lines.length;i++)appendCon(lines[i]);
      lastLineCount=lines.length;
    }
    if(d.done){
      appendCon(d.success?'\n✓ Done.':'\n✗ Failed.');
      currentJob=null;lastLineCount=0;
      enableBtns();fetchStatus();
    }else{
      jobTimer=setTimeout(pollJob,800);
    }
  }catch(e){appendCon('ERROR: '+e);enableBtns();}
}

function appendCon(line){
  const el=document.getElementById('con-out');
  el.textContent+=line+'\n';
  scrollCon();
}
function clearCon(){document.getElementById('con-out').textContent='';}
function setConTitle(t){document.getElementById('con-title').textContent=t;}
function scrollCon(){const el=document.getElementById('con-out');el.scrollTop=el.scrollHeight;}
function enableBtns(){document.querySelectorAll('.btn').forEach(b=>b.disabled=false);}

appendCon('API base: '+_BASE);
fetchStatus();
setInterval(fetchStatus,5000);
"""

HTML = """\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>LibreChat Manager</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#1e1e2e;color:#cdd6f4;min-height:100vh}
.hdr{background:#181825;padding:1.25rem 2rem;border-bottom:1px solid #313244}
.hdr h1{font-size:1.3rem;font-weight:600;color:#cba6f7}
.hdr p{font-size:.82rem;color:#6c7086;margin-top:.2rem}
.wrap{padding:1.5rem 2rem;max-width:960px}
.top-bar{display:flex;align-items:center;gap:.75rem;margin-bottom:1.5rem}
.btn{display:inline-flex;align-items:center;gap:.35rem;padding:.38rem .85rem;border:none;border-radius:6px;font-size:.82rem;font-weight:500;cursor:pointer;transition:opacity .15s}
.btn:hover{opacity:.82}
.btn:disabled{opacity:.4;cursor:not-allowed}
.btn-primary{background:#cba6f7;color:#1e1e2e}
.btn-secondary{background:#313244;color:#cdd6f4}
.btn-logs{background:#89dceb;color:#1e1e2e}
.tag{font-size:.75rem;padding:.15rem .55rem;border-radius:4px;background:#313244;color:#a6adc8}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:1rem;margin-bottom:1.5rem}
.card{background:#181825;border:1px solid #313244;border-radius:10px;padding:1.1rem}
.card-head{display:flex;align-items:center;gap:.55rem;margin-bottom:.45rem}
.dot{width:9px;height:9px;border-radius:50%;flex-shrink:0;transition:background .3s}
.dot.running{background:#a6e3a1;box-shadow:0 0 5px #a6e3a180}
.dot.stopped{background:#f38ba8}
.dot.unknown{background:#6c7086}
.card-name{font-weight:600;font-size:.95rem}
.card-port{font-size:.73rem;color:#6c7086;margin-bottom:.75rem}
.card-btns{display:flex;gap:.4rem}
.console{background:#11111b;border:1px solid #313244;border-radius:8px;padding:1rem}
.con-head{display:flex;align-items:center;justify-content:space-between;margin-bottom:.6rem}
.con-title{font-size:.88rem;font-weight:600;color:#89b4fa}
.con-out{font-family:'Fira Code',monospace;font-size:.78rem;line-height:1.55;height:280px;overflow-y:auto;white-space:pre-wrap;word-break:break-all;color:#a6e3a1}
</style>
</head>
<body>
<div class="hdr">
  <h1>LibreChat Service Manager</h1>
  <p id="hdr-dir">Loading...</p>
</div>
<div class="wrap">
  <div class="top-bar">
    <button class="btn btn-primary" id="btn-all" onclick="restartAll()">&#8635; Restart All</button>
    <span class="tag" id="lc-link" style="display:none"></span>
  </div>
  <div class="grid" id="grid"></div>
  <div class="console">
    <div class="con-head">
      <span class="con-title" id="con-title">Console</span>
      <button class="btn btn-secondary" onclick="clearCon()">Clear</button>
    </div>
    <div class="con-out" id="con-out">Ready.</div>
  </div>
</div>
<script src="app.js"></script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, fmt, *args):
        print(f'[{self.address_string()}] {fmt % args}', flush=True)

    def _send(self, code, ctype, body):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code, obj):
        self._send(code, 'application/json', json.dumps(obj))

    def do_GET(self):
        path = urlparse(self.path).path.rstrip('/')

        if path == '' or path == '/':
            self._send(200, 'text/html; charset=utf-8', HTML)

        elif path == '/app.js':
            self._send(200, 'application/javascript; charset=utf-8', JS_CODE)

        elif path == '/status':
            self._json(200, {
                'status': {s: _get_status(s) for s in SERVICES},
                'ports': PORTS,
                'librechat_dir': LIBRECHAT_DIR,
                'librechat_port': LIBRECHAT_PORT,
            })

        elif path.startswith('/logs/'):
            svc = path[6:]
            if svc not in SERVICES:
                self._json(404, {'error': 'unknown service'})
            else:
                self._send(200, 'text/plain; charset=utf-8', _tail_log(svc))

        elif path.startswith('/job/'):
            jid = path[5:]
            job = _jobs.get(jid)
            if job is None:
                self._json(404, {'error': 'unknown job'})
            else:
                self._json(200, job)

        else:
            self._json(404, {'error': 'not found'})

    def do_POST(self):
        path = urlparse(self.path).path.rstrip('/')

        if path.startswith('/restart/'):
            target = path[9:]
            if target == 'all':
                script = os.path.join(DATA_DIR, 'restart-all.sh')
                label = 'restart-all'
            elif target in SERVICES:
                script = os.path.join(DATA_DIR, f'restart-{target}.sh')
                label = f'restart-{target}'
            else:
                self._json(400, {'error': 'unknown service'})
                return

            if not os.path.isfile(script):
                self._json(500, {'error': f'restart script not found: {script}'})
                return

            jid = _jobs.create(label)
            t = threading.Thread(target=_run_restart, args=(jid, script), daemon=True)
            t.start()
            self._json(202, {'job_id': jid})
        else:
            self._json(404, {'error': 'not found'})


if __name__ == '__main__':
    if not DATA_DIR:
        print('ERROR: DATA_DIR env var not set', flush=True)
        raise SystemExit(1)

    server = HTTPServer(('0.0.0.0', MGR_PORT), Handler)
    print(f'LibreChat Manager listening on port {MGR_PORT}', flush=True)
    print(f'DATA_DIR={DATA_DIR}', flush=True)
    server.serve_forever()
