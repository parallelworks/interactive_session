################################################################################
# Interactive Session Starter - Agent Orchestrator
#
# Purpose: start the orchestrator on ${service_port} (bound on 0.0.0.0 so the
#          platform tunnel can reach it). It registers as a chat model on the
#          workspace, discovers the per-cluster worker agents whose marker matches
#          ${service_marker}, asks them, and synthesizes.
# Runs on: the workspace node
# Called by: session_runner, after inputs.sh is sourced and ${service_port} is set
#
# Variables from inputs.sh:
#   service_name        service dir under the job dir (agent-orchestrator)
#   service_marker      fleet marker (default "worker")
#   service_model       brain model id (e.g. org:glm/glm-5.1)
#   service_allocation  X-Allocation for org:* models
#   service_port        port to bind (set by session_runner)
# Brain credentials come from the runtime environment (PW_API_KEY, PW_PLATFORM_HOST);
# they are exported below for the agent and never written to inputs.sh.
################################################################################
set -x

AGENT_DIR="${PW_PARENT_JOB_DIR}/${service_name:-agent-orchestrator}"

# `pw` on PATH (the orchestrator uses `pw ssh` / `pw sessions`), the brain
# credentials, and the fleet marker.
export PATH="${HOME}/pw:${PATH}"
# Shared resolve_model utility, sparse-checked-out to tools/utils (see the YAML).
export PYTHONPATH="${PW_PARENT_JOB_DIR}/tools/utils${PYTHONPATH:+:${PYTHONPATH}}"
export OPENAI_BASE_URL="https://${PW_PLATFORM_HOST}/api/openai/v1"
export OPENAI_API_KEY="${PW_API_KEY}"      # runtime platform key (not persisted)
export X_ALLOCATION="${service_allocation}"
export MODEL="${service_model}"
export AGENT_MARKER="${service_marker:-worker}"

cd ~/
: > "${PW_PARENT_JOB_DIR}/cancel.sh"

log="${PW_PARENT_JOB_DIR}/orchestrator.out"
python3 "${AGENT_DIR}/orchestrator.py" --port "${service_port}" --host 0.0.0.0 > "${log}" 2>&1 &
pid=$!
echo "kill ${pid}" >> "${PW_PARENT_JOB_DIR}/cancel.sh"
echo "::notice::agent orchestrator started (pid ${pid}) on port ${service_port} | marker=${AGENT_MARKER} | log: ${log}"

# Keep the job (and the session tunnel) alive.
sleep inf
