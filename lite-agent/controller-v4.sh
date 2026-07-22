set -o pipefail
################################################################################
# Interactive Session Controller - Lite Agent
#
# Purpose: prepare the login node to run the lite agent. The agent is pure Python
#          standard library and uses the platform's built-in LLM endpoint as its
#          brain, so there is nothing to install here -- this step just checks the
#          prerequisites. Idempotent.
# Runs on: cluster login node
# Called by: Workflow preprocessing step, after inputs.sh is sourced
#
# Variables from inputs.sh:
#   service_marker      fleet marker (so a matching orchestrator finds this agent)
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

echo "::notice::Lite agent ready | marker=${service_marker} | brain=https://${PW_PLATFORM_HOST}/api/openai/v1 | model=${service_model}"
