#!/usr/bin/env bash
set -o pipefail

################################################################################
# Interactive Session Service Starter - Langflow
#
# Purpose: Start Langflow web service on the allocated port
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - service_port: Allocated port (from session_runner)
#   - service_parent_install_dir: Installation directory
#
# Optional Environment Variables:
#   - service_langflow_data_dir: Langflow data/config directory
#                                (default: ${HOME}/.langflow)
################################################################################

if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir="${HOME}/pw/software"
fi

LANGFLOW_BIN="${service_parent_install_dir}/langflow/venv/bin/langflow"
LANGFLOW_DATA_DIR="${service_langflow_data_dir:-${HOME}/.langflow}"

# Initialize cancel script
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh

if ! [ -f "${LANGFLOW_BIN}" ]; then
    echo "::error title=Error::Langflow binary not found at ${LANGFLOW_BIN}. Run controller first."
    exit 1
fi

mkdir -p "${LANGFLOW_DATA_DIR}"

# ── Start Langflow ─────────────────────────────────────────────────────────────
echo "::group::Starting Langflow"
echo "::notice::Port: ${service_port}"
echo "::notice::Data directory: ${LANGFLOW_DATA_DIR}"

export LANGFLOW_CONFIG_DIR="${LANGFLOW_DATA_DIR}"

"${LANGFLOW_BIN}" run \
    --host 0.0.0.0 \
    --port "${service_port}" \
    --no-open-browser \
    --log-level info \
    > langflow.log 2>&1 &

langflow_pid=$!
echo "kill ${langflow_pid} #langflow" >> cancel.sh
echo "::endgroup::"

# ── Tail logs so platform captures startup output ──────────────────────────────
echo "::group::Langflow logs"
tail -f langflow.log &
logs_pid=$!
echo "kill ${logs_pid} #langflow-logs" >> cancel.sh
echo "::endgroup::"

echo "::notice::Langflow → http://localhost:${service_port}"

sleep inf
