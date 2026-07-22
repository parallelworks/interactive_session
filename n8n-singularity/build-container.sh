#!/usr/bin/env bash
# Builds an n8n Singularity SIF from the official Docker image for upload to
# ghcr.io/parallelworks/n8n:2.0 via ORAS.
#
# Usage: ./build-container.sh [n8n_image_tag]
#   n8n_image_tag  Docker tag to pull (default: 1.123.4)
#
# Prerequisites: singularity (or apptainer), oras
#
# After running, push the resulting n8n.sif:
#   oras push ghcr.io/parallelworks/n8n:2.0 n8n.sif

set -euo pipefail

N8N_IMAGE_TAG=${1:-1.123.4}
SIF_NAME="n8n.sif"

export SINGULARITY_TMPDIR=${SINGULARITY_TMPDIR:-${HOME}/.singularity_tmp}
export SINGULARITY_CACHEDIR=${SINGULARITY_CACHEDIR:-${HOME}/.singularity_cache}
mkdir -p "${SINGULARITY_TMPDIR}" "${SINGULARITY_CACHEDIR}"

echo "Building ${SIF_NAME} from docker://n8nio/n8n:${N8N_IMAGE_TAG}"
singularity build --force "${SIF_NAME}" "docker://n8nio/n8n:${N8N_IMAGE_TAG}"

echo ""
echo "Build complete: ${SIF_NAME}"
echo ""
echo "Push to GitHub Container Registry with:"
echo "  oras push ghcr.io/parallelworks/n8n:2.0 ${SIF_NAME}"
