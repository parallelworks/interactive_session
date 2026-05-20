#!/usr/bin/env bash
set -o pipefail

################################################################################
# Interactive Session Service Starter - Langflow
#
# Purpose: Start Langflow web service on the allocated port
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - service_port: Allocated port (from session_runner)
#   - service_parent_install_dir: Installation directory
#
# Optional Environment Variables:
#   - service_langflow_data_dir: Langflow data/config directory
#                                (default: ${HOME}/.langflow)
################################################################################

if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir="${HOME}/pw/software"
fi

LANGFLOW_VENV="${service_parent_install_dir}/langflow/venv"
LANGFLOW_BIN="${LANGFLOW_VENV}/bin/langflow"
LANGFLOW_DATA_DIR="${service_langflow_data_dir:-${HOME}/.langflow}"

# Initialize cancel script
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh

if ! [ -f "${LANGFLOW_BIN}" ]; then
    echo "::error title=Error::Langflow binary not found at ${LANGFLOW_BIN}. Run controller first."
    exit 1
fi

mkdir -p "${LANGFLOW_DATA_DIR}"

# ── Patch frontend for base-path access ────────────────────────────────────────
# Langflow's Vite frontend is built with BASENAME="" and <base href="/"> hardcoded
# in index.html. Behind a path-prefixed reverse proxy, this breaks in two ways:
#
#  1. Assets: relative paths (assets/index.js) resolve via <base href="/"> to
#     /assets/index.js — the platform can't route these without the session prefix.
#
#  2. React Router: reads window.location.pathname (e.g. /me/session/user/sess/)
#     with no basename configured, finds no matching route, and navigates to
#     /login (without the basepath). Subsequent API calls land on the platform
#     instead of the session service.
#
# Fix: copy the frontend to a session dir, patch index.html via Python (sed is
# unreliable here — & in JS replacement strings expands to the matched text), and
# inject a shim that fixes both routing and network calls at the browser level.
echo "::group::Patching frontend for base path: ${basepath}"

ORIGINAL_FRONTEND=$("${LANGFLOW_VENV}/bin/python" -c \
    "import langflow, os; print(os.path.join(os.path.dirname(langflow.__file__), 'frontend'))" \
    2>/dev/null)

if [ -z "${ORIGINAL_FRONTEND}" ] || [ ! -d "${ORIGINAL_FRONTEND}" ]; then
    echo "::error title=Error::Could not locate Langflow frontend package directory"
    exit 1
fi

SESSION_FRONTEND="${PW_PARENT_JOB_DIR}/langflow-frontend"
echo "::notice::Copying frontend to ${SESSION_FRONTEND}"
cp -r "${ORIGINAL_FRONTEND}" "${SESSION_FRONTEND}"

INDEX_HTML="${SESSION_FRONTEND}/index.html"
if [ ! -f "${INDEX_HTML}" ]; then
    echo "::error title=Error::index.html not found in ${SESSION_FRONTEND}"
    exit 1
fi

# Patch index.html using Python so JS special chars (&&, &, \) are never
# misinterpreted as sed metacharacters in the replacement string.
"${LANGFLOW_VENV}/bin/python" - "${INDEX_HTML}" "${basepath}" <<'PYEOF'
import sys

index_path, basepath = sys.argv[1], sys.argv[2].rstrip('/')

with open(index_path) as f:
    html = f.read()

# Fix the hardcoded <base href="/"> so relative Vite assets (src="assets/...")
# resolve to basepath/assets/... instead of /assets/...
html = html.replace('href="/', f'href="{basepath}/')
html = html.replace('src="/', f'src="{basepath}/')

# Shim injected before </head> so it runs before the React bundle:
#
#  - Location.prototype.pathname: strip basepath so React Router sees / instead
#    of /me/session/user/sess/ and matches its routes correctly.
#
#  - history.pushState / replaceState: add basepath so client-side navigation
#    produces URLs the platform can route back to this session.
#
#  - window.fetch / XMLHttpRequest / WebSocket: prepend basepath to all
#    root-relative calls (/api/v1/...) so they are routed to this session.
shim = f"""<script>(function(){{
  var b="{basepath}";
  // React Router routing fix
  try{{
    var pd=Object.getOwnPropertyDescriptor(Location.prototype,"pathname");
    Object.defineProperty(Location.prototype,"pathname",{{
      get:function(){{var p=pd.get.call(this);return p===b?"/":(p.startsWith(b+"/")?p.slice(b.length):p);}},
      configurable:true
    }});
  }}catch(e){{}}
  // Navigation fix
  function pfx(u){{return typeof u==="string"&&u.charAt(0)==="/"&&u.indexOf(b)!==0?b+u:u;}}
  var oP=history.pushState,oR=history.replaceState;
  history.pushState=function(s,t,u){{return oP.call(this,s,t,pfx(u));}};
  history.replaceState=function(s,t,u){{return oR.call(this,s,t,pfx(u));}};
  // Network call fixes
  var oF=window.fetch;
  window.fetch=function(u,o){{return oF.call(this,typeof u==="string"?pfx(u):u,o);}};
  var oX=XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open=function(m,u){{if(typeof u==="string")arguments[1]=pfx(u);return oX.apply(this,arguments);}};
  var oW=window.WebSocket;
  function PW(url,proto){{return proto?new oW(pfx(url),proto):new oW(pfx(url));}}
  PW.prototype=oW.prototype;PW.CONNECTING=0;PW.OPEN=1;PW.CLOSING=2;PW.CLOSED=3;
  window.WebSocket=PW;
}})();</script>"""

html = html.replace('</head>', shim + '</head>', 1)

with open(index_path, 'w') as f:
    f.write(html)

print(f"Patched {index_path}")
PYEOF

export LANGFLOW_FRONTEND_PATH="${SESSION_FRONTEND}"
export LANGFLOW_ROOT_PATH="${basepath}"
echo "::notice::Frontend patched — LANGFLOW_FRONTEND_PATH and LANGFLOW_ROOT_PATH set"
echo "::endgroup::"

# ── Start Langflow ─────────────────────────────────────────────────────────────
echo "::group::Starting Langflow"
echo "::notice::Port: ${service_port}"
echo "::notice::Data directory: ${LANGFLOW_DATA_DIR}"

export LANGFLOW_CONFIG_DIR="${LANGFLOW_DATA_DIR}"

"${LANGFLOW_BIN}" run \
    --host 0.0.0.0 \
    --port "${service_port}" \
    --no-open-browser \
    --log-level info \
    > langflow.log 2>&1 &

langflow_pid=$!
echo "kill ${langflow_pid} #langflow" >> cancel.sh
echo "::endgroup::"

# ── Tail logs so platform captures startup output ──────────────────────────────
echo "::group::Langflow logs"
tail -f langflow.log &
logs_pid=$!
echo "kill ${logs_pid} #langflow-logs" >> cancel.sh
echo "::endgroup::"

echo "::notice::Langflow → http://localhost:${service_port}"

sleep inf
