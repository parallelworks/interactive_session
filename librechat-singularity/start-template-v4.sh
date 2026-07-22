#!/bin/bash
# Starts the LibreChat stack (MongoDB, MeiliSearch, pgvector, RAG API, LibreChat)
# behind a pw endpoint. The launcher run by `pw endpoints run` reads the
# endpoint-assigned PORT and public PW_ENDPOINT_URL (DOMAIN_CLIENT) at runtime;
# everything else (internal ports, cancel.sh, the Langflow bridge) is prepared
# here first. Subdomain endpoints serve at the root URL, so the v3 index.html
# base-path patch stays disabled (basepath unset).
set -ex

SCRIPTS_DIR=${PW_PARENT_JOB_DIR}/librechat-singularity

if [ -n "${service_parent_install_dir}" ]; then
    container_dir=${service_parent_install_dir}/containers/librechat
    if ! [ -d "${container_dir}" ] && ! [ -w "${service_parent_install_dir}" ]; then
        echo "::warning::container_dir ${container_dir} does not exist and no write permission to ${service_parent_install_dir}. Resetting to ${HOME}/pw/software."
        service_parent_install_dir=${HOME}/pw/software
    fi
else
    service_parent_install_dir=${HOME}/pw/software
fi

# Load singularity/apptainer if not already in PATH
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

# Unset host env vars that can corrupt the container's Node.js/npm runtime.
# On Cray EX and similar HPC systems, LD_LIBRARY_PATH carries PE paths that
# cause Node to load incompatible native libraries.
unset PYTHONPATH PYTHONHOME PERL5LIB PERLLIB PERL5OPT PYTHONSTARTUP LD_LIBRARY_PATH

SIF=${service_parent_install_dir}/containers/librechat

BASE="${librechat_dir:-${HOME}/pw/LibreChat}"
DATA="$BASE/singularity-data"
PID_DIR="$DATA/pids"
LOG_DIR="$DATA/logs"

MONGO_DATA_DIR="${librechat_db:-$DATA/mongodb}"

mkdir -p "$MONGO_DATA_DIR" "$DATA/meili" "$DATA/pgdata" \
         "$BASE/images" "$BASE/uploads" "$BASE/logs" \
         "$PID_DIR" "$LOG_DIR"

# Bind file used to hide kernel FIPS flag from containers whose OpenSSL 3.x
# auto-activates FIPS mode when /proc/sys/crypto/fips_enabled reads 1.
echo 0 > "$DATA/nofips"

# ── Sanitized env file (Apptainer --env-file can't handle bash math exprs) ───

CLEAN_ENV="$DATA/apptainer.env"
grep -Ev '^\s*(#|$)' "$BASE/.env" \
  | grep -E '^[A-Za-z_][A-Za-z0-9_]+=' \
  | grep -Ev '[*()&|`]' \
  > "$CLEAN_ENV" || true
# Precomputed values for JS math expressions that would break --env-file
echo 'BAN_DURATION=7200000'          >> "$CLEAN_ENV"   # 1000 * 60 * 60 * 2
echo 'SESSION_EXPIRY=900000'         >> "$CLEAN_ENV"   # 1000 * 60 * 15
echo 'REFRESH_TOKEN_EXPIRY=604800000' >> "$CLEAN_ENV"  # (1000*60*60*24) * 7


# Unset env vars that were passed in as empty strings
for var in GENAI_MIL_API_KEY JWT_SECRET JWT_REFRESH_SECRET LIBRECHAT_API_KEY LANGFLOW_API_KEY; do
    [ -z "${!var}" ] && unset "$var"
done

# ── Internal port allocation (LibreChat's own port comes from the endpoint) ──

echo "::group::Allocating ports"
MONGODB_PORT=$(pw agent open-port) || { echo "::error title=Error::Failed to allocate MongoDB port"; exit 1; }
[ -n "$MONGODB_PORT" ] || { echo "::error title=Error::No MongoDB port returned"; exit 1; }
echo "::notice::MongoDB port: $MONGODB_PORT"
MEILI_PORT=$(pw agent open-port) || { echo "::error title=Error::Failed to allocate MeiliSearch port"; exit 1; }
[ -n "$MEILI_PORT" ] || { echo "::error title=Error::No MeiliSearch port returned"; exit 1; }
echo "::notice::MeiliSearch port: $MEILI_PORT"
PG_PORT=$(pw agent open-port) || { echo "::error title=Error::Failed to allocate PostgreSQL port"; exit 1; }
[ -n "$PG_PORT" ] || { echo "::error title=Error::No PostgreSQL port returned"; exit 1; }
echo "::notice::PostgreSQL port: $PG_PORT"
RAG_PORT=$(pw agent open-port) || { echo "::error title=Error::Failed to allocate RAG API port"; exit 1; }
[ -n "$RAG_PORT" ] || { echo "::error title=Error::No RAG API port returned"; exit 1; }
echo "::notice::RAG API port: $RAG_PORT"
echo "::endgroup::"

# ── Helper functions ──────────────────────────────────────────────────────────

source "$SCRIPTS_DIR/utils.sh"

# ── Cancel script (run by the cleanup trap at teardown) ───────────────────────

cat > "./cancel.sh" <<EOF
#!/bin/bash
echo "::group::Stopping LibreChat services"
for svc in librechat ragapi pgvector meilisearch mongodb; do
  pidfile="${PID_DIR}/\${svc}.pid"
  if [ -f "\$pidfile" ]; then
    pid=\$(cat "\$pidfile")
    if kill -0 "\$pid" 2>/dev/null; then
      kill "\$pid" && echo "::notice::Stopped \${svc} (PID \$pid)"
      sleep 1
    fi
    rm -f "\$pidfile"
  fi
done
rm -f "${BASE}/.librechat.lock" && echo "::notice::librechat_dir lock removed"
echo "::endgroup::"
EOF
chmod +x "./cancel.sh"

# ── Stop any leftover processes ───────────────────────────────────────────────

echo "::group::Stopping existing processes"
for svc in librechat ragapi pgvector meilisearch mongodb; do
  stop_existing "$svc"
done
echo "::endgroup::"

# ── Reach the Langflow proxy (cross-node / cross-cluster) ─────────────────────
# The OpenAI-compatible Langflow proxy binds 0.0.0.0:<port> on whichever node the
# Langflow job runs on, and librechat.yaml points at http://localhost:<port>/v1.
# Unless that proxy is already on THIS login node we bridge it here with `pw forward`
# so the localhost endpoint keeps resolving (the LibreChat container shares the host
# network namespace, so it reaches the listener). pw forward auto-reconnects.
#
# Crucially, the proxy is NOT always on its resource's login node: when the Langflow
# job is scheduled to a partition it runs on a *compute* node. The submitter records
# the node in the Langflow job's HOSTNAME file (`localhost` for a login node, else the
# compute node's hostname). We forward to that host *through* the Langflow resource's
# login node, so `pw forward -L <port>:<LF_HOST>:<port> <langflow_resource>` works for
# both login-node (LF_HOST=localhost) and compute-node (LF_HOST=<compute>) proxies.
# HOSTNAME lives on the Langflow host's filesystem: read it locally when Langflow shares
# this resource, or over `pw ssh` when it is on another cluster.
_lf_port_file="${PW_PARENT_JOB_DIR}/LANGFLOW_PROXY_PORT"
_lf_host_file="${PW_PARENT_JOB_DIR}/LANGFLOW_PROXY_HOST"
if [ "${langflow_enable_proxy}" = "true" ] && [ -n "${langflow_proxy_dir}" ] \
   && [ -n "${langflow_resource_name}" ] && [ -s "${_lf_port_file}" ]; then
    LF_PROXY_PORT=$(tr -d '[:space:]' < "${_lf_port_file}")
    # Langflow's real node name, mirrored by the controller after it confirmed the proxy
    # is up (so there is no race and no second cross-host query here).
    _proxy_node=$(tr -d '[:space:]' < "${_lf_host_file}" 2>/dev/null)
    if [ "${langflow_scheduler}" = "true" ]; then
        LF_HOST="${_proxy_node:-localhost}"
    else
        LF_HOST="localhost"
    fi
    # Skip only when the proxy is on THIS very node (Langflow co-located here): localhost
    # already reaches its 0.0.0.0 bind and a forward would clash with the proxy's own port.
    _my_host=$(hostname 2>/dev/null); _my_short=$(hostname -s 2>/dev/null || echo "${_my_host}")
    if [ -n "${LF_PROXY_PORT}" ] \
       && [ "${_proxy_node}" != "${_my_host}" ] && [ "${_proxy_node}" != "${_my_short}" ]; then
        echo "::notice::Forwarding Langflow proxy: localhost:${LF_PROXY_PORT} -> ${langflow_resource_name} (${LF_HOST}):${LF_PROXY_PORT}"
        pw forward -L "${LF_PROXY_PORT}:${LF_HOST}:${LF_PROXY_PORT}" "${langflow_resource_name}" \
            > "$LOG_DIR/langflow-proxy-forward.log" 2>&1 &
        echo "kill $! #langflow-proxy-forward" >> ./cancel.sh
    else
        echo "::notice::Langflow proxy is co-located on this node (localhost:${LF_PROXY_PORT}) — no forward needed"
    fi
fi

# ── Launcher: everything that needs the endpoint's PORT / public URL ─────────

export SIF BASE DATA PID_DIR LOG_DIR MONGO_DATA_DIR CLEAN_ENV SCRIPTS_DIR \
       MONGODB_PORT MEILI_PORT PG_PORT RAG_PORT

cat > launch-librechat-${PW_JOB_ID}.sh <<'LAUNCHEOF'
#!/bin/bash
set -ex
source "$SCRIPTS_DIR/utils.sh"
export service_port="${PORT}"

# The public endpoint URL replaces v3's https://<platform-host><basepath>
if [[ "${domain_client}" == "ACTIVATE" ]] && [ -n "${PW_ENDPOINT_URL}" ]; then
    sed -i "s|^DOMAIN_CLIENT=.*|DOMAIN_CLIENT=${PW_ENDPOINT_URL%/}|" "$BASE/.env"
    echo "::notice::DOMAIN_CLIENT set to ${PW_ENDPOINT_URL%/}"
fi

# ── Save runtime state for restart scripts ────────────────────────────────────

cat > "$DATA/service.env" <<ENVEOF
# LibreChat service runtime state — generated at job start.
# Source this file before running start-*.sh scripts standalone.
export SIF="${SIF}"
export BASE="${BASE}"
export DATA="${DATA}"
export PID_DIR="${PID_DIR}"
export LOG_DIR="${LOG_DIR}"
export MONGO_DATA_DIR="${MONGO_DATA_DIR}"
export CLEAN_ENV="${CLEAN_ENV}"
export SCRIPTS_DIR="${SCRIPTS_DIR}"
export MONGODB_PORT=${MONGODB_PORT}
export MEILI_PORT=${MEILI_PORT}
export PG_PORT=${PG_PORT}
export RAG_PORT=${RAG_PORT}
export service_port=${service_port}
export basepath="${basepath:-}"
ENVEOF

# ── Start services ────────────────────────────────────────────────────────────

echo "::group::Starting services"

source "$SCRIPTS_DIR/start-mongodb.sh"
source "$SCRIPTS_DIR/start-meilisearch.sh"
source "$SCRIPTS_DIR/start-pgvector.sh"
source "$SCRIPTS_DIR/start-ragapi.sh"
source "$SCRIPTS_DIR/start-librechat.sh"

echo "::endgroup::"

# ── Generate per-service restart scripts ──────────────────────────────────────
# Each restart script is a 2-line shim: source service.env (to get SCRIPTS_DIR)
# then exec the canonical start-*.sh, which already calls stop_existing before
# starting and handles singularity loading in its standalone detection block.
# Running a restart script is safe while the endpoint is up — it operates in a
# separate subprocess; cancel.sh finds the new PIDs via the PID files.

echo "::notice::Generating restart scripts in $DATA/"

for _svc in mongodb meilisearch pgvector ragapi librechat; do
    cat > "$DATA/restart-${_svc}.sh" <<SHIM
#!/bin/bash
source "\$(dirname "\${BASH_SOURCE[0]}")/service.env"
exec bash "\$SCRIPTS_DIR/start-${_svc}.sh"
SHIM
    chmod +x "$DATA/restart-${_svc}.sh"
done
unset _svc

cat > "$DATA/restart-all.sh" <<'RESTARTALL'
#!/bin/bash
# Restarts all LibreChat services in dependency order.
# Safe to run while the session is active. Ports remain unchanged.
set -e
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _svc in mongodb meilisearch pgvector ragapi librechat; do
    echo "==> Restarting ${_svc}..."
    bash "$_DIR/restart-${_svc}.sh"
    echo "==> ${_svc} restarted."
done
echo "All services restarted successfully."
RESTARTALL
chmod +x "$DATA/restart-all.sh"

echo "::notice::All services running. PIDs in $PID_DIR/"
echo "::notice::Logs in $LOG_DIR/"
echo "::notice::To restart a service:  bash $DATA/restart-mongodb.sh"
echo "::notice::To restart all:        bash $DATA/restart-all.sh"
echo "::notice::Service state:         $DATA/service.env"

# Keep the endpoint alive. Services run as independent background processes;
# restarting any one of them (via the restart-*.sh scripts) does not kill
# this process and therefore does not tear down the endpoint.
exec sleep inf
LAUNCHEOF
chmod +x launch-librechat-${PW_JOB_ID}.sh

# set -e would exit on a non-zero pw exit before the fail-loud block runs
set +e
pw endpoints run ${pw_endpoints_args} -- ./launch-librechat-${PW_JOB_ID}.sh

if [ $? -ne 0 ]; then
    echo "::error title=Error::pw endpoints command failed"
    # Fail loud: without this, wait_for_endpoint polls forever for an endpoint
    # that will never register
    pw workflows runs cancel ${PW_RUN_SLUG}
    exit 1
fi
