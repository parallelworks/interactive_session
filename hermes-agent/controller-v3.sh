set -o pipefail
################################################################################
# Interactive Session Controller - Hermes Agent (worker | orchestrator)
#
# Purpose: prepare the login/workspace node to run the Hermes agent. The agent
#          is pure Python standard library and uses the platform's built-in LLM
#          endpoint as its brain, so there is nothing to install here -- this
#          step just checks the prerequisites. Idempotent.
# Runs on: cluster login node (worker) or workspace node (orchestrator)
# Called by: session_runner, after inputs.sh is sourced
#
# Variables from inputs.sh:
#   hermes_role             worker | orchestrator
#   service_hermes_model    brain model id (as `pw ai models ls` lists it)
#   service_allocation      X-Allocation for org:* models (e.g. "Private LLM Group")
################################################################################

echo "::group::Prerequisites"
if ! command -v python3 >/dev/null 2>&1; then
    echo "::error title=Missing python3::python3 is required on this node but was not found"
    exit 1
fi
echo "::notice::python3 $(python3 --version 2>&1)"
echo "::endgroup::"

echo "::notice::Hermes ${hermes_role} ready | brain=https://${PW_PLATFORM_HOST}/api/openai/v1 | model=${service_hermes_model} | allocation=${service_allocation}"
