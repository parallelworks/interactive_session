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
#   - service_langflow_data_dir:        Langflow data directory
#                                       (default: ${HOME}/pw/.langflow)
#   - service_langflow_config_dir:      LANGFLOW_CONFIG_DIR inside container;
#                                       custom components in <dir>/components/ are
#                                       auto-discovered (default: same as data dir)
#   - service_langflow_components_path: LANGFLOW_COMPONENTS_PATH — additional
#                                       custom components directory; bind-mounted
#                                       only when set (default: unset)
#   - service_langflow_database_url:    LANGFLOW_DATABASE_URL; for SQLite the
#                                       database dir is bind-mounted automatically
#                                       (default: sqlite inside config dir)
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
LANGFLOW_CONFIG_DIR="${service_langflow_config_dir:-${LANGFLOW_DATA_DIR}}"

# Initialize cancel script
# v5 endpoints: no session_runner port or base path. Langflow serves at the
# endpoint's root URL, so the v3 base-path patching below degrades to a no-op.
service_port=$(pw agent open-port) || { echo "::error title=Error::Failed to allocate Langflow port"; exit 1; }
basepath=""

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

# Config dir — create and bind only when it differs from the data dir
if [ "${LANGFLOW_CONFIG_DIR}" != "${LANGFLOW_DATA_DIR}" ]; then
    mkdir -p "${LANGFLOW_CONFIG_DIR}"
    chmod 777 "${LANGFLOW_CONFIG_DIR}" -Rf || true
fi

# Build optional --bind / --env arrays for the singularity exec call
EXTRA_BINDS=()
EXTRA_ENVS=()

# LANGFLOW_CONFIG_DIR bind (always; duplicate bind with data dir is harmless)
EXTRA_BINDS+=(--bind "${LANGFLOW_CONFIG_DIR}:${LANGFLOW_CONFIG_DIR}")

# Optional: custom components path
if [ -n "${service_langflow_components_path}" ]; then
    mkdir -p "${service_langflow_components_path}"
    chmod 777 "${service_langflow_components_path}" || true
    EXTRA_BINDS+=(--bind "${service_langflow_components_path}:${service_langflow_components_path}")
    EXTRA_ENVS+=(--env "LANGFLOW_COMPONENTS_PATH=${service_langflow_components_path}")
fi

# Optional: explicit database URL; bind the parent directory for SQLite absolute paths
if [ -n "${service_langflow_database_url}" ]; then
    if [[ "${service_langflow_database_url}" == sqlite:////* ]]; then
        db_path="${service_langflow_database_url#sqlite:///}"   # strips sqlite:/// → /abs/path.db
        db_dir="$(dirname "${db_path}")"
        mkdir -p "${db_dir}"
        chmod 777 "${db_dir}" || true
        EXTRA_BINDS+=(--bind "${db_dir}:${db_dir}")
    fi
    EXTRA_ENVS+=(--env "LANGFLOW_DATABASE_URL=${service_langflow_database_url}")
fi

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

# ── Optional: auto-import bundled flows ────────────────────────────────────────
# When the combined LibreChat + Langflow workflow ships flow JSONs alongside the
# proxy code (${langflow_proxy_dir}/flows), bind that directory into the container
# and let Langflow import them on startup via LANGFLOW_LOAD_FLOWS_PATH. Imported
# flows are upserted (idempotent) and owned by the superuser, so they get a
# non-null user_id and the proxy discovers them as selectable models.
if [ "${langflow_enable_proxy}" = "true" ] && [ -n "${langflow_proxy_dir}" ]; then
    # Import the user's own flows from ${langflow_proxy_dir}/flows. Optionally also import
    # the test flows bundled in this repo (langflow-singularity/flows, e.g. pw-test-one) —
    # only when ${langflow_import_bundled_flows} is true (on for general-all, off for hsp-all).
    # Everything is merged into one directory so a single LANGFLOW_LOAD_FLOWS_PATH imports it;
    # imported flows are owned by the superuser, so the proxy discovers them as models.
    proxy_flows_import_dir="${PW_PARENT_JOB_DIR}/langflow/import-flows"
    repo_flows_dir="${PW_PARENT_JOB_DIR}/langflow-singularity/flows"
    mkdir -p "${proxy_flows_import_dir}"
    [ -d "${langflow_proxy_dir}/flows" ] && cp -f "${langflow_proxy_dir}/flows/"*.json "${proxy_flows_import_dir}/" 2>/dev/null || true
    if [ "${langflow_import_bundled_flows}" = "true" ] && [ -d "${repo_flows_dir}" ]; then
        cp -f "${repo_flows_dir}/"*.json "${proxy_flows_import_dir}/" 2>/dev/null || true
        echo "::notice::Importing bundled repo flows from ${repo_flows_dir}"
    fi
    if ls "${proxy_flows_import_dir}/"*.json >/dev/null 2>&1; then
        EXTRA_BINDS+=(--bind "${proxy_flows_import_dir}:${proxy_flows_import_dir}")
        EXTRA_ENVS+=(--env "LANGFLOW_LOAD_FLOWS_PATH=${proxy_flows_import_dir}")
        EXTRA_ENVS+=(--env "LANGFLOW_LOAD_FLOWS_OVERWRITE_ON_NAME_MATCH=true")
        echo "::notice::Auto-importing Langflow flows from ${proxy_flows_import_dir}"
    fi

    # ── ACTIVATE platform credentials for OpenAI-compatible flows ───────────────
    # A flow whose Language Model node uses the "OpenAI Compatible API" provider
    # reads its key from ~/.secrets/<PROVIDER>_API_KEY (OPENAI_COMPATIBLE_API_API_KEY).
    # Publish the platform key there and bind ~/.secrets into the container so the
    # flow can call https://${PW_PLATFORM_HOST}/api/openai/v1 with the platform key.
    # Platform org models (org:*) also require an X-Allocation header, which the flow
    # forwards from $PW_ALLOCATION — discover one here. No-op for the GenAI.mil flow.
    if [ -n "${PW_API_KEY}" ]; then
        { set +x; } 2>/dev/null   # do not trace the platform key
        mkdir -p "${HOME}/.secrets"
        printf '%s' "${PW_API_KEY}" > "${HOME}/.secrets/OPENAI_COMPATIBLE_API_API_KEY"
        chmod 600 "${HOME}/.secrets/OPENAI_COMPATIBLE_API_API_KEY" 2>/dev/null || true
        _plat="${PW_PLATFORM_HOST#https://}"
        pw_alloc=""
        for _try in 1 2 3; do
            pw_alloc=$(curl -s -m 15 "https://${_plat}/api/allocations" \
                -H "Authorization: Bearer ${PW_API_KEY}" 2>/dev/null | python3 -c '
import sys, json
try:
    a = json.load(sys.stdin)
    names = [x.get("name", "") for x in a if x.get("name")]
    print(next((n for n in names if "LLM" in n), names[0] if names else ""))
except Exception:
    print("")' 2>/dev/null)
            [ -n "${pw_alloc}" ] && break
            sleep 3
        done
        set -x
        EXTRA_BINDS+=(--bind "${HOME}/.secrets:${HOME}/.secrets")
        if [ -n "${pw_alloc}" ]; then
            EXTRA_ENVS+=(--env "PW_ALLOCATION=${pw_alloc}")
            echo "::notice::Platform X-Allocation for org models: ${pw_alloc}"
        else
            echo "::notice::No platform allocation discovered (org models may need X-Allocation)"
        fi
    fi
fi

# ── Start Langflow ─────────────────────────────────────────────────────────────
echo "::group::Starting Langflow"
echo "::notice::Port: ${service_port}"
echo "::notice::Data directory: ${LANGFLOW_DATA_DIR}"
echo "::notice::Config directory: ${LANGFLOW_CONFIG_DIR}"
echo "::notice::Container: ${container_dir}"
[ -n "${service_langflow_components_path}" ] && echo "::notice::Components path: ${service_langflow_components_path}"
[ -n "${service_langflow_database_url}" ]    && echo "::notice::Database URL: ${service_langflow_database_url}"

singularity exec \
    --writable-tmpfs \
    --bind "${LANGFLOW_DATA_DIR}:${LANGFLOW_DATA_DIR}" \
    --bind "${SESSION_FRONTEND}:${FRONTEND_INSIDE}" \
    --bind "$PWD/container_tmp:/tmp" \
    "${EXTRA_BINDS[@]}" \
    --env LANGFLOW_CONFIG_DIR="${LANGFLOW_CONFIG_DIR}" \
    "${EXTRA_ENVS[@]}" \
    --env LANGFLOW_FRONTEND_PATH="${FRONTEND_INSIDE}" \
    --env LANGFLOW_ROOT_PATH="${basepath}" \
    --env DO_NOT_TRACK="true" \
    --env LANGFLOW_DO_NOT_TRACK="true" \
    --env LANGFLOW_ALEMBIC_LOG_TO_STDOUT="true" \
    --env LANGFLOW_SKIP_AUTH_AUTO_LOGIN="true" \
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

# ── Optional: OpenAI-compatible Langflow proxy ──────────────────────────────────
# When ${langflow_proxy_dir} is set, launch the proxy co-located with Langflow so a
# LibreChat user can pick each Langflow flow as a model. The proxy reads the
# Langflow DB directly (flow discovery) and forwards chat turns to Langflow's run
# API on localhost. Auth, when LANGFLOW_API_KEY is set, is shared with LibreChat.
#
# If the proxy is enabled, it MUST be launchable here — otherwise LANGFLOW_PROXY_PORT is
# never published and LibreChat waits forever. The controller already fails fast on a
# missing proxy dir; re-check (defense in depth) and error rather than silently skip.
if [ "${langflow_enable_proxy}" = "true" ] && { [ -z "${langflow_proxy_dir}" ] || [ ! -d "${langflow_proxy_dir}/langflow_proxy" ]; }; then
    echo "::error title=Langflow proxy code not found::'Start Langflow Proxy?' is enabled but the langflow_proxy package was not found at Langflow Proxy Path '${langflow_proxy_dir:-<empty>}' on the Langflow host ($(hostname)). Stage the proxy code there, or disable the proxy."
    exit 1
fi
if [ "${langflow_enable_proxy}" = "true" ] && [ -n "${langflow_proxy_dir}" ] && [ -d "${langflow_proxy_dir}/langflow_proxy" ]; then
    echo "::group::Starting Langflow proxy"
    proxy_venv="${service_parent_install_dir}/tools/langflow_proxy_venv"
    # Allocate a port dynamically and publish it to the shared job dir so the
    # (parallel) LibreChat job can read it and register the proxy endpoint.
    proxy_port=$(pw agent open-port)
    [ -n "${proxy_port}" ] && echo "${proxy_port}" > "${PW_PARENT_JOB_DIR}/LANGFLOW_PROXY_PORT"
    echo "::notice::Langflow proxy port ${proxy_port} → ${PW_PARENT_JOB_DIR}/LANGFLOW_PROXY_PORT"

    # Resolve the Langflow DB file the proxy queries for flows. SQLAlchemy URLs use
    # four slashes for an absolute path (sqlite:////abs/x.db → /abs/x.db); strip the
    # sqlite:/// prefix exactly as the proxy's own DB layer does.
    if [[ "${service_langflow_database_url}" == sqlite:///* ]]; then
        proxy_db_path="${service_langflow_database_url#sqlite:///}"   # sqlite:////abs → /abs
        case "${proxy_db_path}" in /*) : ;; *) proxy_db_path="/${proxy_db_path}" ;; esac
        # Collapse duplicate slashes: the default URL sqlite:////${HOME}/... yields
        # //home/... (${HOME} already starts with /), and sqlite3's file: URI would
        # otherwise read the first path segment ("home") as an authority and fail.
        proxy_db_path=$(printf '%s' "${proxy_db_path}" | sed 's#/\{2,\}#/#g')
    else
        proxy_db_path="${LANGFLOW_CONFIG_DIR}/langflow.db"
    fi

    proxy_config="${PW_PARENT_JOB_DIR}/langflow/proxy-config.yaml"

    # Optional API-key auth, shared with the LibreChat endpoint via LANGFLOW_API_KEY.
    proxy_api_key_line=""
    if [ -n "${LANGFLOW_API_KEY}" ]; then
        proxy_key_file="${PW_PARENT_JOB_DIR}/langflow/.proxy_api_key"
        printf '%s' "${LANGFLOW_API_KEY}" > "${proxy_key_file}"
        chmod 600 "${proxy_key_file}" || true
        proxy_api_key_line="  api_key_file: \"${proxy_key_file}\""
    fi

    cat > "${proxy_config}" <<PROXYCFG
proxy:
  host: 0.0.0.0
  port: ${proxy_port}
${proxy_api_key_line}
langflow:
  host: 127.0.0.1
  port: ${service_port}
  database_path: "${proxy_db_path}"
PROXYCFG

    # Append an optional user-provided top-level `flows:` block (per-flow model
    # routing). Looked up at ${langflow_proxy_flows_file} first, else flows.yaml
    # next to the proxy code. Without it, every flow is exposed with defaults.
    proxy_flows_file=""
    if [ -n "${langflow_proxy_flows_file}" ] && [ -s "${langflow_proxy_flows_file}" ]; then
        proxy_flows_file="${langflow_proxy_flows_file}"
    elif [ -s "${langflow_proxy_dir}/flows.yaml" ]; then
        proxy_flows_file="${langflow_proxy_dir}/flows.yaml"
    fi
    [ -n "${proxy_flows_file}" ] && cat "${proxy_flows_file}" >> "${proxy_config}"

    if [ -x "${proxy_venv}/bin/python" ]; then
        # Launch uvicorn directly (not bin/langflow_proxy) so a not-yet-created
        # Langflow DB doesn't trip the strict pre-flight validator; the proxy
        # discovers flows lazily and re-reads its config on every request.
        APP_CONFIG_PATH="${proxy_config}" \
        PYTHONPATH="${langflow_proxy_dir}:${PYTHONPATH:-}" \
        "${proxy_venv}/bin/python" -m uvicorn langflow_proxy.main:app \
            --host 0.0.0.0 --port "${proxy_port}" \
            > langflow-proxy.log 2>&1 &
        proxy_pid=$!
        echo "kill ${proxy_pid} #langflow-proxy" >> cancel.sh
        echo "::notice::Langflow proxy → http://localhost:${proxy_port}/v1 (pid ${proxy_pid})"
        tail -f langflow-proxy.log &
        echo "kill $! #langflow-proxy-logs" >> cancel.sh
    else
        echo "::error title=Langflow proxy venv missing::Proxy venv not found at ${proxy_venv} (controller did not build it). Cannot start the proxy that 'Start Langflow Proxy?' requires."
        exit 1
    fi
    echo "::endgroup::"
fi

# The endpoint is the foreground keep-alive: it serves the already-listening
# Langflow port and tears the session down when it exits.
# set -e would exit on a non-zero pw exit before the fail-loud block runs
set +e
pw endpoints http ${pw_endpoints_args} ${service_port}

if [ $? -ne 0 ]; then
    echo "::error title=Error::pw endpoints command failed"
    # Fail loud: without this, wait_for_endpoint polls forever for an endpoint
    # that will never register
    pw workflows runs cancel ${PW_RUN_SLUG}
    exit 1
fi
