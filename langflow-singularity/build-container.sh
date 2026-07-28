#!/usr/bin/env bash
# Builds the Singularity images (SIF) used by the Langflow session:
#   - langflow.sif:          official Langflow image + lancedb (RAG vector database)
#   - hftei-<tag>.sif:       HuggingFace Text Embeddings Inference (embeddings for RAG)
#
# Usage: ./build-container.sh [langflow_image_tag] [hftei_image_tag]
#   langflow_image_tag  Langflow Docker tag to pull (default: 1.9.3)
#   hftei_image_tag     TEI Docker tag to pull (default: cpu-1.6.0)
#
# Prerequisites: singularity (or apptainer), oras
#
# After running, push the resulting SIFs:
#   oras push ghcr.io/parallelworks/langflow:2.0 langflow.sif
#   oras push ghcr.io/parallelworks/hftei:cpu-1.6.0 hftei-cpu-1.6.0.sif

set -euo pipefail

LANGFLOW_IMAGE_TAG=${1:-1.9.3}
HFTEI_IMAGE_TAG=${2:-cpu-1.6.0}

export SINGULARITY_TMPDIR=${HOME}/.singularity_tmp
export SINGULARITY_CACHEDIR=${HOME}/.singularity_cache
mkdir -p "${SINGULARITY_TMPDIR}" "${SINGULARITY_CACHEDIR}"

cat > langflow.def <<EOF
Bootstrap: docker
From: langflowai/langflow:${LANGFLOW_IMAGE_TAG}

%post
    /app/.venv/bin/pip install lancedb
EOF

echo "Building langflow.sif from docker://langflowai/langflow:${LANGFLOW_IMAGE_TAG} (+ lancedb)"
singularity build --force --fakeroot langflow.sif langflow.def
singularity exec langflow.sif /app/.venv/bin/python -c "import lancedb" # smoke-test

echo "Building hftei-${HFTEI_IMAGE_TAG}.sif from docker://ghcr.io/huggingface/text-embeddings-inference:${HFTEI_IMAGE_TAG}"
singularity build --force "hftei-${HFTEI_IMAGE_TAG}.sif" \
    "docker://ghcr.io/huggingface/text-embeddings-inference:${HFTEI_IMAGE_TAG}"

echo ""
echo "Build complete: langflow.sif, hftei-${HFTEI_IMAGE_TAG}.sif"
echo ""
echo "Push to GitHub Container Registry with:"
echo "  oras push ghcr.io/parallelworks/langflow:2.0 langflow.sif"
echo "  oras push ghcr.io/parallelworks/hftei:${HFTEI_IMAGE_TAG} hftei-${HFTEI_IMAGE_TAG}.sif"
