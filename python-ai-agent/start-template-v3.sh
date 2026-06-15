################################################################################
# Interactive Session Starter - Python AI Agent (worker | orchestrator)
#
# Purpose: start the Python AI agent on ${service_port} (bound on 0.0.0.0 so the
#          platform tunnel can reach it).
#            worker       -> agent_server.py  (one per cluster; runs shell there)
#            orchestrator -> orchestrator.py  (on the workspace; coordinates workers)
# Runs on: worker -> cluster login node (scheduler:false); orchestrator -> workspace
# Called by: session_runner, after inputs.sh is sourced and ${service_port} is set
#
# Variables from inputs.sh:
#   agent_role       worker | orchestrator
#   service_name     service dir under the job dir (python-ai-agent)
#   service_cluster  (worker) this cluster's name, used in the agent's answers
#   service_port     port to bind (set by session_runner)
# Brain credentials come from the runtime environment (PW_API_KEY, PW_PLATFORM_HOST)
# and are exported below for the agent; they are never written to inputs.sh.
################################################################################
set -x

AGENT_DIR="${PW_PARENT_JOB_DIR}/${service_name:-python-ai-agent}"

# `pw` on PATH (the orchestrator uses `pw ssh` / `pw sessions`), and the brain
# credentials the agent reads from its environment.
export PATH="${HOME}/pw:${PATH}"
export OPENAI_BASE_URL="https://${PW_PLATFORM_HOST}/api/openai/v1"
export OPENAI_API_KEY="${PW_API_KEY}"      # runtime platform key (not persisted)
export X_ALLOCATION="${service_allocation}"
export MODEL="${service_model}"

cd ~/
: > "${PW_PARENT_JOB_DIR}/cancel.sh"

if [ "${agent_role}" = "orchestrator" ]; then
    log="${PW_PARENT_JOB_DIR}/orchestrator.out"
    python3 "${AGENT_DIR}/orchestrator.py" --port "${service_port}" --host 0.0.0.0 > "${log}" 2>&1 &
else
    export PYAI_CLUSTER="${service_cluster:-${PW_USER}}"
    log="${PW_PARENT_JOB_DIR}/worker.out"
    python3 "${AGENT_DIR}/agent_server.py" --port "${service_port}" --host 0.0.0.0 > "${log}" 2>&1 &
fi

pid=$!
echo "kill ${pid}" >> "${PW_PARENT_JOB_DIR}/cancel.sh"
echo "::notice::python-ai ${agent_role} started (pid ${pid}) on port ${service_port} | log: ${log}"

# Keep the job (and the session tunnel) alive.
sleep inf
