#!/usr/bin/env bash
# Builds an n8n Singularity sandbox from the official Docker image and archives
# it for upload to ghcr.io/parallelworks/n8n:1.0 via ORAS.
#
# Usage: ./build-container.sh [n8n_image_tag]
#   n8n_image_tag  Docker tag to pull (default: 1.123.4)
#
# Prerequisites: singularity (or apptainer), oras
#
# After running, push the resulting n8n.tgz:
#   oras push ghcr.io/parallelworks/n8n:1.0 n8n.tgz

set -euo pipefail

N8N_IMAGE_TAG=${1:-1.123.4}
SANDBOX_DIR="n8n"
ARCHIVE_NAME="n8n.tgz"

echo "Building Singularity sandbox from docker://n8nio/n8n:${N8N_IMAGE_TAG}"
singularity build --sandbox "${SANDBOX_DIR}" "docker://n8nio/n8n:${N8N_IMAGE_TAG}"

echo "Archiving sandbox to ${ARCHIVE_NAME}"
tar -czf "${ARCHIVE_NAME}" "${SANDBOX_DIR}/"

echo ""
echo "Build complete: ${ARCHIVE_NAME}"
echo ""
echo "Push to GitHub Container Registry with:"
echo "  oras push ghcr.io/parallelworks/n8n:1.0 ${ARCHIVE_NAME}"
