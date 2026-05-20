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
# The platform strips the basepath prefix before forwarding requests to this node.
# Langflow's compiled frontend uses root-relative URLs (/assets/..., /api/v1/...)
# which the browser resolves against the origin without the session prefix → 404.
#
# Fix: copy the bundled frontend to a session-specific dir, rewrite asset URLs
# in index.html, and inject a JS interceptor to patch fetch/XHR API calls.
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

# Fix root-relative asset URLs written by the Vite build
sed -i "s|src=\"/|src=\"${basepath}/|g" "${INDEX_HTML}"
sed -i "s|href=\"/|href=\"${basepath}/|g" "${INDEX_HTML}"

# Inject JS interceptor that prepends basepath to all root-relative
# fetch() and XMLHttpRequest calls made by the compiled JS bundle
INTERCEPTOR="<script>(function(){var b=\"${basepath}\";var f=window.fetch;window.fetch=function(u,o){if(typeof u===\"string\"&&u.charAt(0)===\"/\"&&u.indexOf(b)!==0)u=b+u;return f.call(this,u,o)};var x=XMLHttpRequest.prototype.open;XMLHttpRequest.prototype.open=function(m,u){if(typeof u===\"string\"&&u.charAt(0)===\"/\"&&u.indexOf(b)!==0)arguments[1]=b+u;return x.apply(this,arguments)};})();</script>"
sed -i "s|</head>|${INTERCEPTOR}</head>|" "${INDEX_HTML}"

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
