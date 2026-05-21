#!/usr/bin/env python3
"""LibreChat Service Manager — Flask HTTP server."""

import json
import os
import subprocess
import threading
import uuid

from flask import Flask, Response, jsonify, request, stream_with_context

DATA_DIR = os.environ.get('DATA_DIR', '')
LIBRECHAT_PORT = os.environ.get('LIBRECHAT_PORT', '')
MGR_PORT = int(os.environ.get('MGR_PORT', '8080'))

PORTS = {
    'mongodb':     os.environ.get('MONGODB_PORT', ''),
    'meilisearch': os.environ.get('MEILI_PORT', ''),
    'pgvector':    os.environ.get('PG_PORT', ''),
    'ragapi':      os.environ.get('RAG_PORT', ''),
    'librechat':   LIBRECHAT_PORT,
}
LIBRECHAT_DIR = os.path.dirname(DATA_DIR) if DATA_DIR else ''
SERVICES = ['mongodb', 'meilisearch', 'pgvector', 'ragapi', 'librechat']

app = Flask(__name__)


# ── Job store ──────────────────────────────────────────────────────────────────

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


# ── Helpers ────────────────────────────────────────────────────────────────────

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


# ── CSS (shared) ───────────────────────────────────────────────────────────────

CSS = """
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#1e1e2e;color:#cdd6f4;min-height:100vh}
.hdr{background:#181825;padding:1.25rem 2rem;border-bottom:1px solid #313244}
.hdr h1{font-size:1.3rem;font-weight:600;color:#cba6f7}
.hdr p{font-size:.82rem;color:#6c7086;margin-top:.2rem}
.wrap{padding:1.5rem 2rem;max-width:960px}
.top-bar{display:flex;align-items:center;gap:.75rem;margin-bottom:1.5rem;flex-wrap:wrap}
.btn{display:inline-flex;align-items:center;gap:.35rem;padding:.38rem .85rem;border:none;border-radius:6px;font-size:.82rem;font-weight:500;cursor:pointer;transition:opacity .15s;text-decoration:none}
.btn:hover{opacity:.82}
.btn-primary{background:#cba6f7;color:#1e1e2e}
.btn-secondary{background:#313244;color:#cdd6f4}
.btn-logs{background:#89dceb;color:#1e1e2e}
.btn-back{background:#45475a;color:#cdd6f4}
.tag{font-size:.75rem;padding:.15rem .55rem;border-radius:4px;background:#313244;color:#a6adc8}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:1rem;margin-bottom:1.5rem}
.card{background:#181825;border:1px solid #313244;border-radius:10px;padding:1.1rem}
.card-head{display:flex;align-items:center;gap:.55rem;margin-bottom:.45rem}
.dot{width:9px;height:9px;border-radius:50%;flex-shrink:0}
.dot.running{background:#a6e3a1;box-shadow:0 0 5px #a6e3a180}
.dot.stopped{background:#f38ba8}
.dot.unknown{background:#6c7086}
.card-name{font-weight:600;font-size:.95rem}
.card-port{font-size:.73rem;color:#6c7086;margin-bottom:.75rem}
.card-btns{display:flex;gap:.4rem}
.console{background:#11111b;border:1px solid #313244;border-radius:8px;padding:1rem}
.con-head{display:flex;align-items:center;justify-content:space-between;margin-bottom:.6rem}
.con-title{font-size:.88rem;font-weight:600;color:#89b4fa}
.pre{font-family:'Fira Code',monospace;font-size:.78rem;line-height:1.55;white-space:pre-wrap;word-break:break-all;color:#a6e3a1}
.pre-scroll{height:320px;overflow-y:auto}
.notice{padding:.6rem 1rem;border-radius:6px;font-size:.82rem;margin-bottom:1rem}
.notice-ok{background:#1e3a2f;border:1px solid #a6e3a1;color:#a6e3a1}
.notice-err{background:#3a1e2f;border:1px solid #f38ba8;color:#f38ba8}
.notice-info{background:#1e2a3a;border:1px solid #89b4fa;color:#89b4fa}
form{display:inline}
"""

LABELS = {
    'mongodb': 'MongoDB',
    'meilisearch': 'MeiliSearch',
    'pgvector': 'PostgreSQL / pgvector',
    'ragapi': 'RAG API',
    'librechat': 'LibreChat',
}


def _page(title, body, refresh=None):
    """Wrap body HTML in a full page with shared header/CSS."""
    refresh_tag = f'<meta http-equiv="refresh" content="{refresh}">' if refresh else ''
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
{refresh_tag}
<title>{title} — LibreChat Manager</title>
<style>{CSS}</style>
</head>
<body>
<div class="hdr">
  <h1>LibreChat Service Manager</h1>
  <p>{LIBRECHAT_DIR or ''}</p>
</div>
<div class="wrap">
{body}
</div>
</body>
</html>"""


def _html_response(html, status=200, refresh=None):
    r = Response(html, status=status, mimetype='text/html')
    r.headers['Cache-Control'] = 'no-store'
    return r


# ── Routes ─────────────────────────────────────────────────────────────────────

@app.route('/')
def index():
    statuses = {s: _get_status(s) for s in SERVICES}

    lc_tag = ''
    if LIBRECHAT_PORT:
        lc_tag = f'<span class="tag">LibreChat port: {LIBRECHAT_PORT}</span>'

    cards = ''
    for svc in SERVICES:
        st = statuses[svc]
        port = f'port {PORTS[svc]}' if PORTS.get(svc) else ''
        cards += f"""<div class="card">
  <div class="card-head"><span class="dot {st}"></span><span class="card-name">{LABELS[svc]}</span></div>
  <div class="card-port">{port}</div>
  <div class="card-btns">
    <form method="POST" action="restart/{svc}"><button class="btn btn-primary" type="submit">&#8635; Restart</button></form>
    <a class="btn btn-logs" href="logs/{svc}">Logs</a>
  </div>
</div>"""

    body = f"""<div class="top-bar">
  <form method="POST" action="restart/all"><button class="btn btn-primary" type="submit">&#8635; Restart All</button></form>
  {lc_tag}
</div>
<div class="grid">{cards}</div>"""

    return _html_response(_page('Status', body, refresh=10))


@app.route('/restart/<svc>', methods=['POST'])
def restart(svc):
    if svc == 'all':
        script = os.path.join(DATA_DIR, 'restart-all.sh')
        label = 'Restart All'
    elif svc in SERVICES:
        script = os.path.join(DATA_DIR, f'restart-{svc}.sh')
        label = f'Restart {LABELS.get(svc, svc)}'
    else:
        return _html_response(_page('Error', '<p class="notice notice-err">Unknown service.</p>'), 400)

    if not os.path.isfile(script):
        body = f'<p class="notice notice-err">Restart script not found: <code>{script}</code></p>'
        body += '<a class="btn btn-back" href=".">&#8592; Back</a>'
        return _html_response(_page('Error', body), 500)

    jid = _jobs.create(label)
    threading.Thread(target=_run_restart, args=(jid, script), daemon=True).start()

    # Stream the job output directly so no JavaScript is needed.
    def generate():
        yield _page_open(label)
        sent = 0
        import time
        while True:
            job = _jobs.get(jid)
            lines = job['lines']
            if len(lines) > sent:
                for line in lines[sent:]:
                    yield _esc(line) + '\n'
                sent = len(lines)
            if job['done']:
                result = '&#10003; Done.' if job['success'] else '&#10007; Failed.'
                color = '#a6e3a1' if job['success'] else '#f38ba8'
                yield f'\n<span style="color:{color};font-weight:600">{result}</span>\n'
                break
            time.sleep(0.4)
        yield _page_close()

    return Response(stream_with_context(generate()), mimetype='text/html',
                    headers={'Cache-Control': 'no-store', 'X-Accel-Buffering': 'no'})


@app.route('/logs/<svc>')
def logs(svc):
    if svc not in SERVICES:
        return _html_response(_page('Error', '<p class="notice notice-err">Unknown service.</p>'), 404)

    content = _tail_log(svc)
    body = f"""<div class="top-bar">
  <a class="btn btn-back" href="..">&#8592; Back</a>
  <span style="color:#6c7086;font-size:.82rem">Last 100 lines — {LABELS.get(svc, svc)}</span>
</div>
<div class="console">
  <div class="pre pre-scroll">{_esc(content)}</div>
</div>"""
    return _html_response(_page(f'Logs: {svc}', body))


@app.route('/status')
def status():
    return jsonify({
        'status': {s: _get_status(s) for s in SERVICES},
        'ports': PORTS,
        'librechat_dir': LIBRECHAT_DIR,
        'librechat_port': LIBRECHAT_PORT,
    })


@app.route('/headers')
def headers():
    """Debug: show all request headers as seen by this server."""
    lines = '\n'.join(f'{k}: {v}' for k, v in sorted(request.headers))
    return Response(lines, mimetype='text/plain')


# ── Streaming helpers ──────────────────────────────────────────────────────────

def _esc(s):
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def _page_open(title):
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{_esc(title)} — LibreChat Manager</title>
<style>{CSS}</style>
</head>
<body>
<div class="hdr">
  <h1>LibreChat Service Manager</h1>
  <p>{_esc(LIBRECHAT_DIR or '')}</p>
</div>
<div class="wrap">
<div class="top-bar">
  <span style="color:#cba6f7;font-weight:600">{_esc(title)}</span>
</div>
<div class="console">
<div class="con-head"><span class="con-title">Output</span></div>
<div class="pre">"""


def _page_close():
    return """</div>
</div>
<br>
<a class="btn btn-back" href="..">&#8592; Back to main</a>
</div>
</body>
</html>"""


# ── Entry point ────────────────────────────────────────────────────────────────

if __name__ == '__main__':
    if not DATA_DIR:
        print('ERROR: DATA_DIR env var not set', flush=True)
        raise SystemExit(1)

    print(f'LibreChat Manager listening on port {MGR_PORT}', flush=True)
    print(f'DATA_DIR={DATA_DIR}', flush=True)
    app.run(host='0.0.0.0', port=MGR_PORT, threaded=True, debug=False)
