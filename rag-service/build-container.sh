#!/usr/bin/env bash
# Builds the rag-service Singularity SIF (Python env with pinned deps) from
# rag-service.def for upload to ghcr.io/parallelworks/rag-service via ORAS.
#
# Usage: ./build-container.sh [tag]
#   tag  ghcr tag the SIF is destined for (default: 1.0) -- only used in the
#        push hint; the SIF file itself is always rag-service.sif
#
# Prerequisites: singularity (or apptainer) with unprivileged --fakeroot,
# internet access (docker://python pull + pip installs).
#
# After running, push the resulting rag-service.sif (see tools/oras/oras):
#   printf '%s' "$GHCR_TOKEN" | oras login ghcr.io -u <github-user> --password-stdin
#   oras push ghcr.io/parallelworks/rag-service:<tag> rag-service.sif
#   oras logout ghcr.io
# A brand-new ghcr package is private by default: make it public in the GitHub
# package settings before workflows can pull it anonymously.

set -euo pipefail
cd "$(dirname "$0")"

TAG=${1:-1.0}
SIF_NAME="rag-service.sif"

export SINGULARITY_TMPDIR=${SINGULARITY_TMPDIR:-${HOME}/.singularity_tmp}
export SINGULARITY_CACHEDIR=${SINGULARITY_CACHEDIR:-${HOME}/.singularity_cache}
mkdir -p "${SINGULARITY_TMPDIR}" "${SINGULARITY_CACHEDIR}"

echo "Building ${SIF_NAME} from rag-service.def"
singularity build --force --fakeroot "${SIF_NAME}" rag-service.def

echo ""
echo "Smoke-testing ${SIF_NAME}"
singularity exec "${SIF_NAME}" python3 -c "import lancedb, sentence_transformers, watchdog, pypdf; print('deps ok:', lancedb.__version__)"

echo ""
echo "Build complete: $(du -h "${SIF_NAME}" | cut -f1) ${SIF_NAME}"
echo "Push to GitHub Container Registry with:"
echo "  oras push ghcr.io/parallelworks/rag-service:${TAG} ${SIF_NAME}"
