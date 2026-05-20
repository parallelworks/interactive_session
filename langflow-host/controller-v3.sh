#!/usr/bin/env bash
set -o pipefail
set -x

################################################################################
# Interactive Session Controller - Langflow
#
# Purpose: Install Langflow using uv in a Python virtual environment.
#          uv itself is installed if not already present.
# Runs on: Controller node with internet access
# Called by: Workflow preprocessing step
#
# Required Environment Variables:
#   - service_parent_install_dir: Install root (default: ${HOME}/pw/software)
################################################################################

if ! [ -z "${PW_PARENT_JOB_DIR}" ]; then
    cd "${PW_PARENT_JOB_DIR}"
fi

if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir="${HOME}/pw/software"
fi

LANGFLOW_DIR="${service_parent_install_dir}/langflow"
LANGFLOW_VENV="${LANGFLOW_DIR}/venv"
LANGFLOW_BIN="${LANGFLOW_VENV}/bin/langflow"

mkdir -p "${LANGFLOW_DIR}"

# ── uv Installation ────────────────────────────────────────────────────────────
echo "::group::uv Installation"

UV_BIN=""
if command -v uv &>/dev/null; then
    UV_BIN="$(command -v uv)"
elif [ -f "${HOME}/.local/bin/uv" ]; then
    UV_BIN="${HOME}/.local/bin/uv"
fi

if [ -z "${UV_BIN}" ]; then
    echo "::notice::uv not found — installing..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    # The uv installer places the binary in ~/.local/bin; update PATH for this session
    export PATH="${HOME}/.local/bin:${PATH}"
    UV_BIN="${HOME}/.local/bin/uv"
fi

if ! [ -f "${UV_BIN}" ]; then
    echo "::error title=Error::uv installation failed — ${UV_BIN} not found"
    exit 1
fi

echo "::notice::uv version: $(${UV_BIN} --version)"
echo "::endgroup::"

# ── Langflow Installation ──────────────────────────────────────────────────────
echo "::group::Langflow Installation"

if ! [ -f "${LANGFLOW_BIN}" ]; then
    echo "::notice::Creating Python 3.11 virtual environment at ${LANGFLOW_VENV}..."
    "${UV_BIN}" venv --python 3.11 "${LANGFLOW_VENV}"

    echo "::notice::Installing Langflow into ${LANGFLOW_VENV}..."
    "${UV_BIN}" pip install --python "${LANGFLOW_VENV}/bin/python" langflow

    if ! [ -f "${LANGFLOW_BIN}" ]; then
        echo "::error title=Error::Langflow binary not found after install at ${LANGFLOW_BIN}"
        exit 1
    fi
else
    echo "::notice::Langflow already installed at ${LANGFLOW_BIN} — skipping"
fi

LANGFLOW_VERSION=$("${LANGFLOW_BIN}" --version 2>/dev/null || echo "unknown")
echo "::notice::Langflow ${LANGFLOW_VERSION} ready at ${LANGFLOW_BIN}"
echo "::endgroup::"
