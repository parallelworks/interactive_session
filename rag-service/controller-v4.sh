set -o pipefail
################################################################################
# Interactive Session Controller - RAG Service
#
# Purpose: provision the rag-service runtime on the login node (which has
#          internet): pull the dependency SIF container from ghcr and
#          pre-download the embedding model into a cache on the shared
#          filesystem, so the start script also works on compute nodes without
#          internet (scheduler: true). Idempotent.
# Runs on: cluster login node
# Called by: Workflow preprocessing step, after inputs.sh is sourced
#
# Variables from inputs.sh:
#   service_name                 service dir under the job dir (rag-service)
#   service_docs_dir             directory of documents to index (required)
#   service_embedding_model_id   sentence-transformers model id
#   service_parent_install_dir   install root (default ${HOME}/pw/software)
################################################################################
set -x

source tools/oras/libs.sh

CONTAINER_TAG="1.0"

if [ -n "${service_parent_install_dir}" ]; then
    container_sif=${service_parent_install_dir}/containers/rag-service.sif
    if ! [ -f "${container_sif}" ] && ! [ -w "${service_parent_install_dir}" ]; then
        echo "::warning::container_sif ${container_sif} does not exist and no write permission to ${service_parent_install_dir}. Resetting to ${HOME}/pw/software."
        service_parent_install_dir=${HOME}/pw/software
    fi
else
    service_parent_install_dir=${HOME}/pw/software
fi

MODELS_DIR="${service_parent_install_dir/#\~/$HOME}/models"
container_sif=${service_parent_install_dir}/containers/rag-service.sif
sandbox_dir=${service_parent_install_dir}/containers/rag-service-sandbox

echo "::group::Prerequisites"
if [ -z "${service_docs_dir}" ]; then
    echo "::error title=Missing docs_dir::the docs_dir input is required"
    exit 1
fi
docs_dir_abs="${service_docs_dir/#\~/$HOME}"
if [ ! -d "${docs_dir_abs}" ]; then
    echo "::error title=Bad docs_dir::docs_dir '${service_docs_dir}' does not exist on this cluster"
    exit 1
fi
if ! which singularity &> /dev/null; then
    if module load apptainer 2>/dev/null; then
        echo "::notice::Loaded apptainer module"
    elif module load singularity 2>/dev/null; then
        echo "::notice::Loaded singularity module"
    else
        echo "::error title=Error::singularity/apptainer not found in PATH and could not be loaded via module"
        exit 1
    fi
fi
echo "::endgroup::"

mkdir -p ${service_parent_install_dir}/containers "${MODELS_DIR}"
chmod a+rX ${service_parent_install_dir}/containers

# Download the SIF only when it is not already present (idempotent)
if ! [ -f "${container_sif}" ]; then
    echo "::group::rag-service SIF Download"
    oras_pull_file ghcr.io/parallelworks/rag-service:${CONTAINER_TAG} rag-service.sif ${container_sif}
    if [ ! -s ${container_sif} ]; then
        echo "::error title=Error::Failed to download file ${container_sif}"
        exit 1
    fi
    chmod a+r ${container_sif}
    echo "::endgroup::"
fi

# Prefer running the SIF directly; if this node cannot mount it, unpack a
# sandbox once (the start template runs the same probe on the service node)
if singularity exec "${container_sif}" /bin/true > /dev/null 2>&1; then
    container_ref="${container_sif}"
else
    echo "::notice::Cannot mount SIF on this node; building sandbox fallback"
    export SINGULARITY_TMPDIR=${HOME}/.singularity_tmp
    export SINGULARITY_CACHEDIR=${HOME}/.singularity_cache
    mkdir -p $SINGULARITY_TMPDIR $SINGULARITY_CACHEDIR
    if ! [ -d "${sandbox_dir}" ]; then
        singularity build --fakeroot --force --sandbox "${sandbox_dir}" "${container_sif}" || \
            { echo "::error title=Error::sandbox build failed"; exit 1; }
    fi
    container_ref="${sandbox_dir}"
fi

echo "::group::Embedding model cache"
# Save the model as a plain directory ${MODELS_DIR}/<org>/<name> on the shared
# filesystem (no hub-cache "models--" naming); compute nodes load that path
# offline. The hub download itself goes through a throwaway cache dir.
EMBEDDING_MODEL="${service_embedding_model_id:-BAAI/bge-small-en-v1.5}"
if [ -f "${MODELS_DIR}/${EMBEDDING_MODEL}/modules.json" ]; then
    echo "::notice::model already cached at ${MODELS_DIR}/${EMBEDDING_MODEL}"
else
    export HF_HOME=$(mktemp -d)
    singularity exec --bind "${MODELS_DIR}" --bind "${HF_HOME}" "${container_ref}" \
        python3 -c "
import os, sys
from sentence_transformers import SentenceTransformer
mid, out = sys.argv[1], sys.argv[2]
m = SentenceTransformer(mid, device='cpu')
dst = os.path.join(out, mid)
m.save(dst)
print(f'saved {mid} (dim={m.get_sentence_embedding_dimension()}) -> {dst}')
" "${EMBEDDING_MODEL}" "${MODELS_DIR}" \
        || { rm -rf "${HF_HOME}"; echo "::error title=Model download failed::could not cache the embedding model"; exit 1; }
    rm -rf "${HF_HOME}"
    unset HF_HOME
fi
echo "::endgroup::"

echo "::notice::rag-service ready | container=${container_ref} | model=${EMBEDDING_MODEL} | docs=${docs_dir_abs}"
