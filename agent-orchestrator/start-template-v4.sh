################################################################################
# Interactive Session Starter - Agent Orchestrator
#
# Purpose: start the orchestrator on the endpoint-assigned port. `pw endpoints
#          run --openai` registers it as a chat model in the platform Chat and
#          AI providers. It discovers the per-cluster worker agents whose marker
#          matches ${service_marker}, asks them, and synthesizes.
# Runs on: the workspace node
# Called by: Workflow after controller setup, with inputs.sh sourced
#
# Variables from inputs.sh:
#   service_name       service dir under the job dir (agent-orchestrator)
#   service_marker     fleet marker (default "worker")
#   service_model      brain model id (e.g. org:glm/glm-5.1)
#   service_allocation X-Allocation for org:* models
#   pw_endpoints_args  Arguments for pw endpoints run (--name, ...)
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
# Run with the agent's private venv python (see tools/utils/agent_env.sh).
. "${PW_PARENT_JOB_DIR}/tools/utils/agent_env.sh"
PYBIN="$(agent_python_bin)"
export OPENAI_BASE_URL="https://${PW_PLATFORM_HOST}/api/openai/v1"
export OPENAI_API_KEY="${PW_API_KEY}"      # runtime platform key (not persisted)
export X_ALLOCATION="${service_allocation}"
export MODEL="${service_model}"
export AGENT_MARKER="${service_marker:-worker}"
# System prompt from the form (written by preprocessing); falls back to the
# built-in default if this file is missing/empty.
export AGENT_SYSTEM_PROMPT_FILE="${PW_PARENT_JOB_DIR}/system_prompt.txt"

cd ~/

echo "::notice::Starting agent orchestrator behind pw endpoint (--openai) | marker=${AGENT_MARKER}"
# {port} is replaced by pw endpoints run with the local port it forwards to
pw endpoints run ${pw_endpoints_args} --openai -- "${PYBIN}" "${AGENT_DIR}/orchestrator.py" \
    --port {port} \
    --host 127.0.0.1

if [ $? -ne 0 ]; then
    # The pw endpoints command blocks for the life of the service, so it also
    # returns non-zero when the workflow cancels this job after a *successful*
    # launch - which is exactly how wait_for_endpoint releases the run. Treating
    # that as a failure cancelled the whole run from inside the compute job:
    # ollama_gguf runs 24-26 finished "canceled" with the service up, until
    # #1055 disabled this line for that service. Only a launch that never
    # registered its endpoint is a real failure.
    served_name=$(printf '%s' "${pw_endpoints_args}" | sed -n 's/.*--name[ =]\{1,\}\([^ ]*\).*/\1/p')
    if [ -n "${served_name}" ] && pw endpoints list 2>/dev/null | awk '{print $1}' | grep -qxF "${served_name}"; then
        echo "::notice::Endpoint ${served_name} served until this job was cancelled; exiting cleanly"
        exit 0
    fi
    echo "::error title=Error::pw endpoints command failed"
    # Fail loud: without this, wait_for_endpoint polls forever for an endpoint
    # that will never register
    pw workflows runs cancel ${PW_RUN_SLUG}
    exit 1
fi
