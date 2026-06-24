# Shared Python environment for the stdlib-only agents (lite-agent,
# agent-orchestrator, hermes-agent). Sourced by each service's controller
# (which creates the venv) and start script (which runs the agent with it).
#
# Why: the agents target whatever python3 a node happens to ship, which varies
# (3.9 on general clusters, 3.6 on HSP login nodes). A private venv under the
# install dir gives a controlled, isolated, explicit interpreter instead of
# "whatever python3 is on PATH". It is created with --without-pip (no network,
# no ensurepip) because the agents need only the standard library; it inherits
# the base python's VERSION, so the agent code must stay 3.6-compatible.
#
# Uses: service_parent_install_dir (from inputs.sh; default ${HOME}/pw/software).

_agent_venv_dir() {
    local base="${service_parent_install_dir:-$HOME/pw/software}"
    base="${base/#\~/$HOME}"        # expand a leading ~
    printf '%s/agent-venv' "$base"
}

# Create the venv if missing (idempotent). Falls back silently to the system
# python3 if venv creation is unavailable, so a node without the venv module
# still works. Safe to call from a controller. Prints platform annotations.
agent_python_setup() {
    local venv; venv="$(_agent_venv_dir)"
    if [ -x "${venv}/bin/python" ]; then
        echo "::notice::agent venv present: ${venv} ($("${venv}/bin/python" --version 2>&1))"
        return 0
    fi
    if mkdir -p "$(dirname "${venv}")" 2>/dev/null \
        && python3 -m venv --without-pip "${venv}" >/dev/null 2>&1 \
        && [ -x "${venv}/bin/python" ]; then
        echo "::notice::created agent venv: ${venv} ($("${venv}/bin/python" --version 2>&1))"
    else
        rm -rf "${venv}" 2>/dev/null || true
        echo "::warning::could not create venv at ${venv}; falling back to system python3 ($(python3 --version 2>&1))"
    fi
}

# Echo the interpreter the agent should run with: the venv python if present,
# otherwise the system python3. Use as: PYBIN="$(agent_python_bin)".
agent_python_bin() {
    local venv; venv="$(_agent_venv_dir)"
    if [ -x "${venv}/bin/python" ]; then
        printf '%s/bin/python' "${venv}"
    else
        command -v python3
    fi
}
