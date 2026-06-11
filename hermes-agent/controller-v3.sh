set -o pipefail
################################################################################
# Interactive Session Controller - Hermes Agent (worker | orchestrator)
#
# Purpose: install the Hermes agent and point it at the platform's OpenAI-
#          compatible endpoint (the "brain"). Idempotent; runs on the
#          controller/login node, which has internet access.
# Runs on: controller/login node (worker) or workspace node (orchestrator)
# Called by: session_runner preprocessing, after inputs.sh is sourced
#
# Variables from inputs.sh:
#   hermes_role                 worker | orchestrator
#   service_parent_install_dir  install root (default ${HOME}/pw/software)
#   service_hermes_model        model name as the platform lists it
#   service_openai_base_url     platform OpenAI-compatible endpoint
#   service_hermes_install_cmd  command that installs hermes (see Hermes docs)
#   PW_PLATFORM_TOKEN           platform token (org secret) -> OPENAI_API_KEY
################################################################################

if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir="${HOME}/pw/software"
fi
mkdir -p "${service_parent_install_dir}"

echo "::group::Prerequisites"
if ! command -v python3 >/dev/null 2>&1; then
    echo "::error title=Error::python3 is required on this node but was not found"
    exit 1
fi
echo "::notice::python3 $(python3 --version 2>&1)"
echo "::endgroup::"

echo "::group::Install Hermes agent"
if command -v hermes >/dev/null 2>&1; then
    echo "::notice::hermes already installed: $(command -v hermes)"
elif [ -n "${service_hermes_install_cmd}" ]; then
    # CONFIRM the install command against the Hermes docs and set it as the
    # `hermes_install_cmd` input (or org var). e.g. an official curl|sh installer
    # or `pipx install hermes-agent`. https://hermes-agent.nousresearch.com/docs/
    echo "::notice::Installing hermes via provided command"
    eval "${service_hermes_install_cmd}" || {
        echo "::error title=Error::hermes install command failed"; exit 1; }
else
    echo "::warning title=Hermes not installed::No hermes binary and no \
hermes_install_cmd given. The agent server will run in STUB mode (plumbing only). \
Set the hermes_install_cmd input to install the real agent."
fi
echo "::endgroup::"

echo "::group::Configure brain (platform OpenAI-compatible endpoint)"
# Hermes reads provider config from ~/.hermes/.env. For an OpenAI-compatible
# proxy that is OPENAI_BASE_URL + OPENAI_API_KEY. CONFIRM exact keys against:
#   https://hermes-agent.nousresearch.com/docs/integrations/providers
mkdir -p "${HOME}/.hermes"
HERMES_ENV="${HOME}/.hermes/.env"
: > "${HERMES_ENV}"
echo "OPENAI_BASE_URL=${service_openai_base_url}" >> "${HERMES_ENV}"
echo "OPENAI_API_KEY=${PW_PLATFORM_TOKEN}"        >> "${HERMES_ENV}"
chmod 600 "${HERMES_ENV}"
if command -v hermes >/dev/null 2>&1 && [ -n "${service_hermes_model}" ]; then
    hermes config set model "${service_hermes_model}" || \
        echo "::warning::could not set hermes model; set it manually per docs"
fi
echo "::notice::brain endpoint = ${service_openai_base_url} | model = ${service_hermes_model}"
echo "::endgroup::"
