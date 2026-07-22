set -o pipefail
################################################################################
# Interactive Session Controller - Agent Orchestrator
#
# Purpose: prepare the workspace node to run the orchestrator. It is a small
#          Python standard-library agent that uses the platform's built-in LLM
#          endpoint as its brain and reaches the per-cluster worker agents over
#          `pw ssh`, so there is nothing to install -- this just checks
#          prerequisites. Idempotent.
# Runs on: the workspace node
# Called by: Workflow preprocessing step, after inputs.sh is sourced
#
# Variables from inputs.sh:
#   service_marker      fleet marker; only matching workers are coordinated
#   service_model       brain model id (as `pw ai models ls` lists it)
#   service_allocation  X-Allocation for org:* models (e.g. "Private LLM Group")
################################################################################

echo "::group::Prerequisites"
if ! command -v python3 >/dev/null 2>&1; then
    echo "::error title=Missing python3::python3 is required on this node but was not found"
    exit 1
fi
echo "::notice::python3 $(python3 --version 2>&1)"

# Provision the agent's private Python venv under the install dir.
. "${PW_PARENT_JOB_DIR}/tools/utils/agent_env.sh"
agent_python_setup
echo "::endgroup::"

echo "::notice::Agent orchestrator ready | marker=${service_marker} | brain=https://${PW_PLATFORM_HOST}/api/openai/v1 | model=${service_model}"
