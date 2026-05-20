#!/usr/bin/env bash
# Builds a Langflow Singularity sandbox from the official Docker image and archives
# it for upload to ghcr.io/parallelworks/langflow:1.0 via ORAS.
#
# Usage: ./build-container.sh [langflow_image_tag]
#   langflow_image_tag  Docker tag to pull (default: latest)
#
# Prerequisites: singularity (or apptainer), oras
#
# After running, push the resulting langflow.tgz:
#   oras push ghcr.io/parallelworks/langflow:1.0 langflow.tgz

set -euo pipefail

LANGFLOW_IMAGE_TAG=${1:-1.9.3}
SANDBOX_DIR="langflow"
ARCHIVE_NAME="langflow.tgz"

echo "Building Singularity sandbox from docker://langflowai/langflow:${LANGFLOW_IMAGE_TAG}"
singularity build --sandbox "${SANDBOX_DIR}" "docker://langflowai/langflow:${LANGFLOW_IMAGE_TAG}"

echo "Archiving sandbox to ${ARCHIVE_NAME}"
tar -czf "${ARCHIVE_NAME}" "${SANDBOX_DIR}/"

echo ""
echo "Build complete: ${ARCHIVE_NAME}"
echo ""
echo "Push to GitHub Container Registry with:"
echo "  oras push ghcr.io/parallelworks/langflow:1.0 ${ARCHIVE_NAME}"
