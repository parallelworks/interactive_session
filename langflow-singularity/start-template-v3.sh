#!/usr/bin/env bash
# start-template-v3.sh — Langflow via Singularity (runs on compute node)
#
# Uses the sandbox downloaded by controller-v3.sh.
# Patches the Langflow frontend for reverse-proxy base-path access,
# then launches Langflow bound to the allocated port.

set -o pipefail
set -x

################################################################################
# Required Environment Variables:
#   - service_port:               Allocated port (from session_runner)
#   - service_parent_install_dir: Installation directory
#   - basepath:                   Session URL base path (e.g. /me/session/user/sess/)
#   - PW_PARENT_JOB_DIR:          Job working directory
#
# Optional Environment Variables:
#   - service_langflow_data_dir:  Langflow data/config directory
#                                 (default: ${HOME}/pw/.langflow)
################################################################################

if [ -n "${service_parent_install_dir}" ]; then
    container_dir=${service_parent_install_dir}/containers/langflow
    if ! [ -d "${container_dir}" ] && ! [ -w "${service_parent_install_dir}" ]; then
        echo "::warning::container_dir ${container_dir} does not exist and no write permission to ${service_parent_install_dir}. Resetting to ${HOME}/pw/software."
        service_parent_install_dir=${HOME}/pw/software
    fi
else
    service_parent_install_dir=${HOME}/pw/software
fi

container_dir=${service_parent_install_dir}/containers/langflow
LANGFLOW_DATA_DIR="${service_langflow_data_dir:-${HOME}/pw/.langflow}"

# Initialize cancel script
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh

if ! [ -d "${container_dir}" ]; then
    echo "::error title=Error::Langflow container not found at ${container_dir}. Run controller first."
    exit 1
fi

# ── Load singularity/apptainer ─────────────────────────────────────────────────
if ! which singularity &> /dev/null; then
    if module load apptainer 2>/dev/null; then
        echo "::notice::Loaded apptainer module"
    elif module load singularity 2>/dev/null; then
        echo "::notice::Loaded singularity module"
    else
        echo "::error title=Error::singularity/apptainer not found in PATH and could not be loaded via module"
        exit 1
    fi
else
    echo "::notice::singularity already available in PATH"
fi

# Unset host env vars that can corrupt the container's Python runtime.
# On Cray EX and similar HPC systems, LD_LIBRARY_PATH carries PE paths that
# cause Python to load incompatible native libraries.
unset PYTHONPATH PYTHONHOME PERL5LIB PERLLIB PERL5OPT PYTHONSTARTUP LD_LIBRARY_PATH

# SSL_CERT_FILE on RHEL/EL hosts points to /etc/pki/ca-trust/... which does
# not exist inside the Debian-based Langflow container. Override it to the
# Debian CA bundle so HTTPS calls (telemetry, component downloads) work.
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

mkdir -p "${LANGFLOW_DATA_DIR}"

# Per-job /tmp prevents cross-user permission conflicts on shared nodes
mkdir -p "$PWD/container_tmp"
echo "rm -rf $PWD/container_tmp" >> cancel.sh

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
# Fix: copy the frontend out of the container to a session dir, patch index.html
# via Python (sed is unreliable here — & in JS replacement strings expands to the
# matched text), inject a shim, and bind-mount the patched version back in.
echo "::group::Patching frontend for base path: ${basepath}"

FRONTEND_INSIDE=$(singularity exec "${container_dir}" python3 -c \
    "import langflow, os; print(os.path.join(os.path.dirname(langflow.__file__), 'frontend'))" \
    2>/dev/null)

if [ -z "${FRONTEND_INSIDE}" ]; then
    echo "::error title=Error::Could not locate Langflow frontend inside container"
    exit 1
fi
echo "::notice::Frontend inside container: ${FRONTEND_INSIDE}"

SESSION_FRONTEND="${PW_PARENT_JOB_DIR}/langflow-frontend"

# Copy the frontend from the container to the session directory.
# PW_PARENT_JOB_DIR is bind-mounted at the same path so cp can write to the host.
singularity exec \
    --bind "${PW_PARENT_JOB_DIR}:${PW_PARENT_JOB_DIR}" \
    "${container_dir}" \
    cp -r "${FRONTEND_INSIDE}" "${SESSION_FRONTEND}"

INDEX_HTML="${SESSION_FRONTEND}/index.html"
if [ ! -f "${INDEX_HTML}" ]; then
    echo "::error title=Error::index.html not found in ${SESSION_FRONTEND}"
    exit 1
fi

# Patch index.html using Python so JS special chars (&&, &, \) are never
# misinterpreted as sed metacharacters in the replacement string.
python3 - "${INDEX_HTML}" "${basepath}" <<'PYEOF'
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

echo "::notice::Frontend patched — binding ${SESSION_FRONTEND} → ${FRONTEND_INSIDE}"
echo "::endgroup::"

# ── Start Langflow ─────────────────────────────────────────────────────────────
echo "::group::Starting Langflow"
echo "::notice::Port: ${service_port}"
echo "::notice::Data directory: ${LANGFLOW_DATA_DIR}"
echo "::notice::Container: ${container_dir}"

singularity exec \
    --writable-tmpfs \
    --bind "${LANGFLOW_DATA_DIR}:${LANGFLOW_DATA_DIR}" \
    --bind "${SESSION_FRONTEND}:${FRONTEND_INSIDE}" \
    --bind "$PWD/container_tmp:/tmp" \
    --env LANGFLOW_CONFIG_DIR="${LANGFLOW_DATA_DIR}" \
    --env LANGFLOW_FRONTEND_PATH="${FRONTEND_INSIDE}" \
    --env LANGFLOW_ROOT_PATH="${basepath}" \
    "${container_dir}" \
    langflow run \
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
