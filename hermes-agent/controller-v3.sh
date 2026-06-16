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
#   service_interface   dashboard | chat (dashboard needs the web UI pre-built)
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

# Dashboard interface needs the web UI built once (login node has node/npm via
# the installer). The build lands in hermes_cli/web_dist; start uses --skip-build.
if [ "${service_interface}" = "dashboard" ]; then
    web_dist_index="${HOME}/.hermes/hermes-agent/hermes_cli/web_dist/index.html"
    if [ -f "${web_dist_index}" ]; then
        echo "::notice::Dashboard web UI already built"
    else
        echo "::group::Build Hermes dashboard web UI (one-time, a few minutes)"
        build_log="${PW_PARENT_JOB_DIR}/dashboard-build.out"
        # `hermes dashboard` builds the SPA then serves it; we just need the build,
        # so launch it on a throwaway loopback port and stop it once dist exists.
        hermes dashboard --no-open --host 127.0.0.1 --port 19119 > "${build_log}" 2>&1 &
        build_pid=$!
        for _ in $(seq 1 150); do
            [ -f "${web_dist_index}" ] && break
            sleep 2
        done
        pkill -P "${build_pid}" 2>/dev/null || true
        kill "${build_pid}" 2>/dev/null || true
        echo "::endgroup::"
        if [ -f "${web_dist_index}" ]; then
            echo "::notice::Dashboard web UI built"
        else
            echo "::error title=Dashboard build failed::web UI did not build; see ${build_log}"
            exit 1
        fi
    fi
fi

echo "::notice::Hermes ready | interface=${service_interface} | brain=https://${PW_PLATFORM_HOST}/api/openai/v1 | model=${service_model} | allocation=${service_allocation}"
