#!/usr/bin/env bash
# Builds the Streamlit Singularity SIF from streamlit.def for upload to
# ghcr.io/parallelworks/streamlit:1.0 via ORAS.
#
# Usage: ./build-container.sh
#
# Prerequisites: singularity (or apptainer) with fakeroot support
#
# After running, push the resulting streamlit.sif:
#   oras push ghcr.io/parallelworks/streamlit:1.0 streamlit.sif

set -euo pipefail

cd "$(dirname "$0")"
SIF_NAME="streamlit.sif"

export SINGULARITY_TMPDIR=${SINGULARITY_TMPDIR:-${HOME}/.singularity_tmp}
export SINGULARITY_CACHEDIR=${SINGULARITY_CACHEDIR:-${HOME}/.singularity_cache}
mkdir -p "${SINGULARITY_TMPDIR}" "${SINGULARITY_CACHEDIR}"

echo "Building ${SIF_NAME} from streamlit.def"
singularity build --force --fakeroot "${SIF_NAME}" streamlit.def

singularity exec "${SIF_NAME}" streamlit version

echo ""
echo "Build complete: ${SIF_NAME}"
echo ""
echo "Push to GitHub Container Registry with:"
echo "  oras push ghcr.io/parallelworks/streamlit:1.0 ${SIF_NAME}"
