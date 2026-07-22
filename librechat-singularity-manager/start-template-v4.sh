#!/bin/bash
# Serves the LibreChat manager (Flask) through a pw endpoint. The manager reads
# LibreChat's runtime state (service.env) and restarts its services on demand.
# Subdomain endpoints serve at the root URL, so BASEPATH stays empty.
set -ex

# MANAGER_SCRIPTS_DIR must be saved before service.env is sourced — service.env
# overwrites SCRIPTS_DIR with the librechat-singularity path.
# When the script is inlined into run.sh, BASH_SOURCE[0] resolves to run.sh in
# the run dir; fall back to PW_PARENT_JOB_DIR/librechat-singularity-manager.
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

# ── Wait for LibreChat's runtime state ─────────────────────────────────────────

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
LIBRECHAT_PORT=$service_port

# ── Build SSH prefix for running commands on LibreChat's compute node ─────────
# HOSTNAME is written when the librechat job starts, which is before service.env
# is written, so it is guaranteed to exist here.

LIBRECHAT_JOB_DIR="${librechat_job_dir:-${PW_PARENT_JOB_DIR}/librechat}"
LIBRECHAT_HOSTNAME_FILE="${LIBRECHAT_JOB_DIR}/HOSTNAME"

_retries=20
until [ -f "$LIBRECHAT_HOSTNAME_FILE" ]; do
    if [ "$_retries" -le 0 ]; then
        echo "::warning::HOSTNAME file not found at ${LIBRECHAT_HOSTNAME_FILE} after retries — restart commands will run locally"
        break
    fi
    echo "Waiting for HOSTNAME file ($LIBRECHAT_HOSTNAME_FILE) — retries left: $_retries"
    sleep 30
    _retries=$(( _retries - 1 ))
done
unset _retries

if [ -f "$LIBRECHAT_HOSTNAME_FILE" ]; then
    LIBRECHAT_HOSTNAME=$(tr -d '[:space:]' < "$LIBRECHAT_HOSTNAME_FILE")
else
    LIBRECHAT_HOSTNAME=""
fi

if [ -n "${resource_uri:-}" ]; then
    if [ "${scheduler:-false}" = "true" ] && [ -n "${LIBRECHAT_HOSTNAME:-}" ]; then
        # Reach LibreChat's compute node: `pw ssh <login> -- ssh <node> <cmd>`.
        #  - `--` stops `pw`'s own (cobra) flag parser from eating the inner ssh's -o
        #    flags; without it `pw ssh ... ssh -o ...` fails: "unknown shorthand flag: 'o'".
        #  - The inner ssh runs with no TTY, so it can't answer a host-key prompt:
        #    StrictHostKeyChecking=no + UserKnownHostsFile=/dev/null accept the node
        #    without prompting and without writing any persistent file on the cluster.
        #  - BatchMode + ConnectTimeout fail fast instead of hanging; LogLevel=ERROR
        #    silences the "Permanently added"/"known by other names" warnings; -T because
        #    we always run a command, never an interactive shell.
        LIBRECHAT_SSH="pw ssh ${resource_uri} -- ssh -T -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15 ${LIBRECHAT_HOSTNAME}"
    else
        LIBRECHAT_SSH="pw ssh ${resource_uri}"
    fi
    echo "::notice::LIBRECHAT_SSH=${LIBRECHAT_SSH}"
else
    LIBRECHAT_SSH=""
    echo "::notice::LIBRECHAT_SSH not set (resource_uri='${resource_uri:-}') — restart commands will run locally"
fi

# ── Serve the manager behind the endpoint ─────────────────────────────────────

export FLASK_ENV MANAGER_SCRIPTS_DIR DATA LIBRECHAT_PORT MONGODB_PORT MEILI_PORT \
       PG_PORT RAG_PORT LIBRECHAT_SSH

cat > launch-manager-${PW_JOB_ID}.sh <<'LAUNCHEOF'
#!/bin/bash
MGR_PORT="${PORT}" \
DATA_DIR="${DATA}" \
LIBRECHAT_PORT="${LIBRECHAT_PORT}" \
MONGODB_PORT="${MONGODB_PORT}" \
MEILI_PORT="${MEILI_PORT}" \
PG_PORT="${PG_PORT}" \
RAG_PORT="${RAG_PORT}" \
BASEPATH="" \
LIBRECHAT_SSH="${LIBRECHAT_SSH}" \
    exec "${FLASK_ENV}/bin/python" "${MANAGER_SCRIPTS_DIR}/server.py"
LAUNCHEOF
chmod +x launch-manager-${PW_JOB_ID}.sh

# set -e would exit on a non-zero pw exit before the fail-loud block runs
set +e
pw endpoints run ${pw_endpoints_args} -- ./launch-manager-${PW_JOB_ID}.sh

if [ $? -ne 0 ]; then
    echo "::error title=Error::pw endpoints command failed"
    # Fail loud: without this, wait_for_endpoint polls forever for an endpoint
    # that will never register
    pw workflows runs cancel ${PW_RUN_SLUG}
    exit 1
fi
