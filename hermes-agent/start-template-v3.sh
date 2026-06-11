################################################################################
# Interactive Session Starter - Hermes Agent (worker | orchestrator)
#
# Purpose: start the Hermes agent's HTTP front-end on ${service_port} (0.0.0.0).
#          worker       -> agent_server.py (one task-runner per cluster)
#          orchestrator -> orchestrator.py (coordinates workers via pw ssh)
# Runs on: worker -> cluster login node (scheduler:false); orchestrator -> workspace
# Called by: session_runner, after inputs.sh is sourced and ${service_port} is set
#
# Variables from inputs.sh:
#   hermes_role                worker | orchestrator
#   service_port               port to bind (set by session_runner; pinned for workers)
#   service_name               service dir name under the job dir (hermes-agent)
#   service_openai_base_url    platform OpenAI-compatible endpoint
#   PW_PLATFORM_TOKEN          platform token -> OPENAI_API_KEY for the agent
#   HERMES_WORKERS             (orchestrator) comma-separated worker cluster names
#   HERMES_AGENT_PORT          (orchestrator) port the workers listen on
################################################################################
set -x

AGENT_DIR="${PW_PARENT_JOB_DIR}/${service_name:-hermes-agent}"

# Make pw / pw agent reachable, and give the agent its brain credentials.
export PATH="${HOME}/pw:${PATH}"
export OPENAI_BASE_URL="${service_openai_base_url}"
export OPENAI_API_KEY="${PW_PLATFORM_TOKEN}"

cd ~/
rm -f "${PW_PARENT_JOB_DIR}/service.pid"
: > "${PW_PARENT_JOB_DIR}/cancel.sh"

if [ "${hermes_role}" = "orchestrator" ]; then
    export HERMES_WORKERS="${HERMES_WORKERS}"
    export HERMES_AGENT_PORT="${HERMES_AGENT_PORT:-8717}"
    python3 "${AGENT_DIR}/orchestrator.py" --port "${service_port}" --host 0.0.0.0 \
        > "${PW_PARENT_JOB_DIR}/orchestrator.out" 2>&1 &
else
    export HERMES_CLUSTER="${PW_USER:-worker}"
    python3 "${AGENT_DIR}/agent_server.py" --port "${service_port}" --host 0.0.0.0 \
        > "${PW_PARENT_JOB_DIR}/worker.out" 2>&1 &
fi
pid="$!"
echo "${pid}" >> "${PW_PARENT_JOB_DIR}/service.pid"
echo "kill ${pid}" >> "${PW_PARENT_JOB_DIR}/cancel.sh"

# Keep the job (and the session tunnel) alive.
sleep inf
