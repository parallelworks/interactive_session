#!/bin/bash
set -ex

# MANAGER_SCRIPTS_DIR must be saved before service.env is sourced — service.env
# overwrites SCRIPTS_DIR with the librechat-singularity path.
# When session_runner inlines this script into run.sh, BASH_SOURCE[0] resolves to
# run.sh in the job dir; fall back to PW_PARENT_JOB_DIR/librechat-singularity-manager.
_src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_src_dir/server.py" ]; then
    MANAGER_SCRIPTS_DIR="$_src_dir"
else
    MANAGER_SCRIPTS_DIR="${PW_PARENT_JOB_DIR}/librechat-singularity-manager"
fi
unset _src_dir

FLASK_ENV="${service_parent_install_dir:-${HOME}/pw/software}/tools/flask"

if [ ! -f "${FLASK_ENV}/bin/flask" ]; then
    echo "::error title=Error::Flask venv not found at ${FLASK_ENV}. Run the controller first."
    exit 1
fi

# ── Load singularity/apptainer (needed by the restart scripts Flask calls) ─────

if ! which singularity &>/dev/null; then
    if module load apptainer 2>/dev/null; then
        echo "::notice::Loaded apptainer module"
    elif module load singularity 2>/dev/null; then
        echo "::notice::Loaded singularity module"
    else
        echo "::error title=Error::singularity/apptainer not found in PATH and could not be loaded via module"
        exit 1
    fi
fi

# ── Resolve service ports ──────────────────────────────────────────────────────

# service_port is injected by session_runner as the manager's port.
# service.env also exports service_port (LibreChat's port) — save it first.
MANAGER_PORT=$service_port

SVC_ENV="${librechat_dir:-${HOME}/pw/LibreChat}/singularity-data/service.env"

_retries=10
until [ -f "$SVC_ENV" ]; do
    if [ "$_retries" -le 0 ]; then
        echo "::error title=Error::service.env not found at $SVC_ENV after 10 minutes"
        echo "Is a librechat-singularity session running? Set librechat_dir to the correct path."
        exit 1
    fi
    echo "Waiting for service.env ($SVC_ENV) — retries left: $_retries"
    sleep 60
    _retries=$(( _retries - 1 ))
done

source "$SVC_ENV"
# service_port now holds LibreChat's port; DATA, SCRIPTS_DIR, etc. are set.
LIBRECHAT_PORT=$service_port
export service_port=$MANAGER_PORT   # restore manager's port

# ── Cancel script ─────────────────────────────────────────────────────────────

cat > "${PW_PARENT_JOB_DIR}/cancel.sh" <<'EOF'
#!/bin/bash
pidfile="$(dirname "$0")/manager.pid"
[ -f "$pidfile" ] && kill "$(cat "$pidfile")" 2>/dev/null || true
EOF
chmod +x "${PW_PARENT_JOB_DIR}/cancel.sh"

# ── Start the manager server on the host ──────────────────────────────────────

MGR_PORT="${MANAGER_PORT}" \
DATA_DIR="${DATA}" \
LIBRECHAT_PORT="${LIBRECHAT_PORT}" \
MONGODB_PORT="${MONGODB_PORT}" \
MEILI_PORT="${MEILI_PORT}" \
PG_PORT="${PG_PORT}" \
RAG_PORT="${RAG_PORT}" \
BASEPATH="${basepath:-}" \
    "${FLASK_ENV}/bin/python" "${MANAGER_SCRIPTS_DIR}/server.py" &

SERVER_PID=$!
echo $SERVER_PID > "${PW_PARENT_JOB_DIR}/manager.pid"
echo "::notice::Manager server started (PID $SERVER_PID)"

# ── Wait for the server to accept connections ─────────────────────────────────

echo "::notice::Waiting for manager on port $MANAGER_PORT..."
_i=0
until curl -sf "http://localhost:$MANAGER_PORT/" > /dev/null 2>&1; do
    _i=$((_i + 1))
    if [ $_i -ge 30 ]; then
        echo "::error title=Error::Manager server did not start on port $MANAGER_PORT"
        exit 1
    fi
    sleep 1
done
echo "::notice::LibreChat Manager is ready"

# ── Keep the job alive ────────────────────────────────────────────────────────

wait $SERVER_PID
