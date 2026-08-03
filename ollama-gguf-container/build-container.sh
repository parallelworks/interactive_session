#!/usr/bin/env bash
# Builds an Ollama Singularity SIF from the official Docker image for upload to
# ghcr.io/parallelworks/ollama-gguf via ORAS.
#
# Usage: ./build-container.sh [ollama_image_tag]
#   ollama_image_tag  Docker tag to pull (default: 0.32.5)
#
# Prerequisites: singularity (or apptainer), oras
#
# After running, push the resulting ollama-gguf.sif:
#   oras push ghcr.io/parallelworks/ollama-gguf:<tag> ollama-gguf.sif

set -euo pipefail

OLLAMA_IMAGE_TAG=${1:-0.32.5}
SIF_NAME="ollama-gguf.sif"

export SINGULARITY_TMPDIR=${SINGULARITY_TMPDIR:-${HOME}/.singularity_tmp}
export SINGULARITY_CACHEDIR=${SINGULARITY_CACHEDIR:-${HOME}/.singularity_cache}
mkdir -p "${SINGULARITY_TMPDIR}" "${SINGULARITY_CACHEDIR}"

echo "Building ${SIF_NAME} from docker://ollama/ollama:${OLLAMA_IMAGE_TAG}"
singularity build --force "${SIF_NAME}" "docker://ollama/ollama:${OLLAMA_IMAGE_TAG}"

singularity exec "${SIF_NAME}" /bin/ollama --version

echo ""
echo "Build complete: ${SIF_NAME}"
echo ""
echo "Push to GitHub Container Registry with:"
echo "  oras push ghcr.io/parallelworks/ollama-gguf:${OLLAMA_IMAGE_TAG} ${SIF_NAME}"
