#!/bin/bash
set -ex

# MANAGER_SCRIPTS_DIR must be saved before service.env is sourced — service.env
# overwrites SCRIPTS_DIR with the librechat-singularity path.
MANAGER_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# service_port is injected by session_runner as the manager's port.
# service.env also exports service_port (LibreChat's port) — save it first.
MANAGER_PORT=$service_port

SVC_ENV="${librechat_dir:-${HOME}/pw/LibreChat}/singularity-data/service.env"

if [ ! -f "$SVC_ENV" ]; then
    echo "::error title=Error::service.env not found at $SVC_ENV"
    echo "Is a librechat-singularity session running? Set librechat_dir to the correct path."
    exit 1
fi

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

# ── Start the manager server ──────────────────────────────────────────────────

export MGR_PORT=$MANAGER_PORT
export DATA_DIR=$DATA
export LIBRECHAT_PORT=$LIBRECHAT_PORT
export MONGODB_PORT=$MONGODB_PORT
export MEILI_PORT=$MEILI_PORT
export PG_PORT=$PG_PORT
export RAG_PORT=$RAG_PORT

python3 "$MANAGER_SCRIPTS_DIR/librechat-singularity-manager/server.py" &
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
