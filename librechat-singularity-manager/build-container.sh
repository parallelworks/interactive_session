#!/usr/bin/env bash
# Builds the librechat-manager Singularity sandbox and stores it at
# ${HOME}/pw/software/containers/librechat-manager.
#
# Run once from a machine with internet access and singularity/apptainer.
# The sandbox is then available to all sessions on the same shared filesystem.
#
# Usage: ./build-container.sh [container_dir]
#   container_dir  Override destination (default: ${HOME}/pw/software/containers/librechat-manager)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_DIR="${1:-${HOME}/pw/software/containers/librechat-manager}"

echo "Building librechat-manager container → ${CONTAINER_DIR}"

mkdir -p "$(dirname "${CONTAINER_DIR}")"

singularity build --sandbox "${CONTAINER_DIR}" "${SCRIPT_DIR}/librechat-manager.def"

chmod -R a+rX "${CONTAINER_DIR}"

echo "Done: ${CONTAINER_DIR}"
