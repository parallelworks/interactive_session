################################################################################
# Interactive Session Starter - Lite Agent (one per cluster)
#
# Purpose: start the lite agent on the endpoint-assigned port. It runs shell
#          commands on THIS cluster; `pw endpoints run --openai` registers it as
#          a chat model in the platform Chat and AI providers. It advertises its
#          fleet marker at /_agent so an agent-orchestrator with the same marker
#          discovers it.
# Runs on: cluster login node (scheduler:false)
# Called by: Workflow after controller setup, with inputs.sh sourced
#
# Variables from inputs.sh:
#   service_name       service dir under the job dir (lite-agent)
#   service_cluster    this cluster's name, used in the agent's answers
#   service_marker     fleet marker (default "worker")
#   pw_endpoints_args  Arguments for pw endpoints run (--name, ...)
# Brain credentials come from the runtime environment (PW_API_KEY, PW_PLATFORM_HOST)
# and are exported below for the agent; they are never written to inputs.sh.
################################################################################
set -x

AGENT_DIR="${PW_PARENT_JOB_DIR}/${service_name:-lite-agent}"

export PATH="${HOME}/pw:${PATH}"
# Shared resolve_model utility, sparse-checked-out to tools/utils (see the YAML).
export PYTHONPATH="${PW_PARENT_JOB_DIR}/tools/utils${PYTHONPATH:+:${PYTHONPATH}}"
# Run with the agent's private venv python (see tools/utils/agent_env.sh).
. "${PW_PARENT_JOB_DIR}/tools/utils/agent_env.sh"
PYBIN="$(agent_python_bin)"
export OPENAI_BASE_URL="https://${PW_PLATFORM_HOST}/api/openai/v1"
export OPENAI_API_KEY="${PW_API_KEY}"      # runtime platform key (not persisted)
export X_ALLOCATION="${service_allocation}"
export MODEL="${service_model}"
export AGENT_CLUSTER="${service_cluster:-${PW_USER}}"
export AGENT_MARKER="${service_marker:-worker}"
# System prompt from the form (written by preprocessing); the agent falls back to
# its built-in default if this file is missing/empty.
export AGENT_SYSTEM_PROMPT_FILE="${PW_PARENT_JOB_DIR}/system_prompt.txt"

cd ~/

echo "::notice::Starting lite agent behind pw endpoint (--openai) | marker=${AGENT_MARKER} | cluster=${AGENT_CLUSTER}"
# {port} is replaced by pw endpoints run with the local port it forwards to
pw endpoints run ${pw_endpoints_args} --openai -- "${PYBIN}" "${AGENT_DIR}/agent_server.py" \
    --port {port} \
    --host 127.0.0.1

if [ $? -ne 0 ]; then
    echo "::error title=Error::pw endpoints command failed"
    # Fail loud: without this, wait_for_endpoint polls forever for an endpoint
    # that will never register
    pw workflows runs cancel ${PW_RUN_SLUG}
    exit 1
fi
