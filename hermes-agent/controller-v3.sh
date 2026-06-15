set -o pipefail
################################################################################
# Interactive Session Controller - Hermes Agent (NousResearch Hermes)
#
# Purpose: install the real Hermes Agent (https://github.com/NousResearch/hermes-agent)
#          on the login node, which has internet. The official installer brings
#          its own uv / Python / Node, so the only hard prerequisites here are
#          curl + python3. Idempotent: the installer preserves an existing
#          install, and we skip it entirely if `hermes` is already on PATH.
# Runs on: cluster login node (scheduler:false)
# Called by: session_runner, after inputs.sh is sourced
#
# Variables from inputs.sh:
#   service_model       brain model id (as `pw ai models ls` lists it)
#   service_allocation  X-Allocation for org:* models (e.g. "Private LLM Group")
################################################################################

echo "::group::Prerequisites"
for bin in python3 curl bash; do
    command -v "$bin" >/dev/null 2>&1 || { echo "::error title=Missing $bin::$bin is required on this node but was not found"; exit 1; }
done
echo "::notice::python3 $(python3 --version 2>&1)"
echo "::endgroup::"

export PATH="${HOME}/.local/bin:${PATH}"

if command -v hermes >/dev/null 2>&1; then
    echo "::notice::Hermes already installed: $(hermes --version 2>&1 | head -1)"
else
    echo "::group::Install Hermes Agent (this can take a few minutes)"
    # --skip-setup: no interactive wizard; --non-interactive: no prompts;
    # --skip-browser: skip the Playwright/browser-tool download we don't need.
    curl -fsSL https://hermes-agent.nousresearch.com/install.sh \
        | bash -s -- --skip-setup --non-interactive --skip-browser
    echo "::endgroup::"
    command -v hermes >/dev/null 2>&1 || { echo "::error title=Install failed::hermes not on PATH after install"; exit 1; }
    echo "::notice::Installed: $(hermes --version 2>&1 | head -1)"
fi

echo "::notice::Hermes ready | brain=https://${PW_PLATFORM_HOST}/api/openai/v1 | model=${service_model} | allocation=${service_allocation}"
