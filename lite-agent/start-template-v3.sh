################################################################################
# Interactive Session Starter - Lite Agent (one per cluster)
#
# Purpose: start the lite agent on ${service_port} (bound on 0.0.0.0 so the
#          platform tunnel can reach it). It runs shell commands on THIS cluster,
#          registers as a chat model, and advertises its fleet marker at /_agent
#          so an agent-orchestrator with the same marker discovers it.
# Runs on: cluster login node (scheduler:false)
# Called by: session_runner, after inputs.sh is sourced and ${service_port} is set
#
# Variables from inputs.sh:
#   service_name     service dir under the job dir (lite-agent)
#   service_cluster  this cluster's name, used in the agent's answers
#   service_marker   fleet marker (default "worker")
#   service_port     port to bind (set by session_runner)
# Brain credentials come from the runtime environment (PW_API_KEY, PW_PLATFORM_HOST)
# and are exported below for the agent; they are never written to inputs.sh.
################################################################################
set -x

AGENT_DIR="${PW_PARENT_JOB_DIR}/${service_name:-lite-agent}"

export PATH="${HOME}/pw:${PATH}"
export OPENAI_BASE_URL="https://${PW_PLATFORM_HOST}/api/openai/v1"
export OPENAI_API_KEY="${PW_API_KEY}"      # runtime platform key (not persisted)
export X_ALLOCATION="${service_allocation}"
export MODEL="${service_model}"
export AGENT_CLUSTER="${service_cluster:-${PW_USER}}"
export AGENT_MARKER="${service_marker:-worker}"

cd ~/
: > "${PW_PARENT_JOB_DIR}/cancel.sh"

log="${PW_PARENT_JOB_DIR}/lite-agent.out"
python3 "${AGENT_DIR}/agent_server.py" --port "${service_port}" --host 0.0.0.0 > "${log}" 2>&1 &
pid=$!
echo "kill ${pid}" >> "${PW_PARENT_JOB_DIR}/cancel.sh"
echo "::notice::lite agent started (pid ${pid}) on port ${service_port} | marker=${AGENT_MARKER} | cluster=${AGENT_CLUSTER}"

# Keep the job (and the session tunnel) alive.
sleep inf
