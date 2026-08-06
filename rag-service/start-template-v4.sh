################################################################################
# Interactive Session Starter - RAG Service
#
# Purpose: start the two rag-service processes on the execution node, both
#          inside the dependency SIF container pulled by controller-v4.sh:
#          1. indexer.py in the background (sole writer of the LanceDB table),
#             logging into the job dir, with a cancel.sh that kills it;
#          2. rag_server.py in the foreground wrapped by `pw endpoints run`,
#             which assigns the local port ({port}) and exposes the search API
#             at https://<name>.activate.pw/.
# Runs on: login node (scheduler:false) or compute node (scheduler:true).
#          Compute nodes may have no internet: the container and the
#          embedding-model cache live on the shared filesystem, and offline
#          mode is forced so nothing tries to download.
# Called by: Workflow after controller setup, with inputs.sh sourced
#
# Variables from inputs.sh:
#   service_name                 service dir under the job dir (rag-service)
#   service_docs_dir             directory of documents to index (required)
#   service_table_name           LanceDB table name
#   service_embedding_model_id   sentence-transformers model id
#   service_chunk_chars          chunk size (characters)
#   service_chunk_overlap        chunk overlap (characters)
#   service_default_top_k        default top_k for /search
#   service_parent_install_dir   install root (default ${HOME}/pw/software)
#   pw_endpoints_args            arguments for pw endpoints run (--name, ...)
################################################################################
set -x

JOB_DIR="${PW_PARENT_JOB_DIR:-${PWD}}"
SERVICE_DIR="${JOB_DIR}/${service_name:-rag-service}"

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

export PATH="${HOME}/pw:${PATH}"

# Load singularity/apptainer if not already in PATH
if ! which singularity &> /dev/null; then
    if module load apptainer 2>/dev/null; then
        echo "::notice::Loaded apptainer module"
    elif module load singularity 2>/dev/null; then
        echo "::notice::Loaded singularity module"
    else
        echo "::error title=Error::singularity/apptainer not found in PATH and could not be loaded via module"
        pw workflows runs cancel ${PW_RUN_SLUG}
        exit 1
    fi
fi

if ! [ -f "${container_sif}" ]; then
    echo "::error title=Error::Missing container image ${container_sif} -- controller-v4.sh did not run?"
    pw workflows runs cancel ${PW_RUN_SLUG}
    exit 1
fi

# HPC env hygiene: host paths in these can shadow the container's libraries
unset PYTHONPATH PYTHONHOME PERL5LIB PERLLIB PERL5OPT PYTHONSTARTUP LD_LIBRARY_PATH

# Prefer running the SIF directly; some nodes cannot mount it (no squashfs
# support), in which case unpack it once into a sandbox directory. The probe
# must run HERE: with scheduler:true this is a compute node whose mount
# support can differ from the login node's.
if singularity exec "${container_sif}" /bin/true > /dev/null 2>&1; then
    echo "::notice::SIF image is runnable on this node"
    container_ref="${container_sif}"
else
    echo "::notice::Cannot mount SIF on this node; using sandbox directory"
    export SINGULARITY_TMPDIR=${HOME}/.singularity_tmp
    export SINGULARITY_CACHEDIR=${HOME}/.singularity_cache
    mkdir -p $SINGULARITY_TMPDIR $SINGULARITY_CACHEDIR
    if ! [ -d "${sandbox_dir}" ]; then
        # Offline-safe: pure local unpack of the already-downloaded SIF
        singularity build --fakeroot --force --sandbox "${sandbox_dir}" "${container_sif}" || \
            { echo "::error title=Error::sandbox build failed"; pw workflows runs cancel ${PW_RUN_SLUG}; exit 1; }
    fi
    container_ref="${sandbox_dir}"
fi

# The model must come from the plain-directory cache the controller saved
# under ${MODELS_DIR}/<org>/<name> (resolve_model_path in rag_common.py) --
# fail loud rather than attempt a download on a node with no internet.
export RAG_MODELS_DIR="${MODELS_DIR}"
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1

export RAG_DOCS_DIR="${service_docs_dir/#\~/$HOME}"
# The LanceDB dataset (and its state file) live under the run's job dir
export RAG_DB_DIR="${JOB_DIR}/rag-db"
export RAG_TABLE="${service_table_name:-activate_rag}"
export RAG_EMBEDDING_MODEL="${service_embedding_model_id:-BAAI/bge-small-en-v1.5}"
export RAG_CHUNK_CHARS="${service_chunk_chars:-700}"
export RAG_CHUNK_OVERLAP="${service_chunk_overlap:-80}"
export RAG_DEFAULT_TOP_K="${service_default_top_k:-8}"

# Host env (RAG_*, SENTENCE_TRANSFORMERS_HOME, offline flags) passes into the
# container; binds cover paths that may sit outside the default $HOME bind.
CONTAINER_RUN="singularity exec --bind ${RAG_DOCS_DIR} --bind ${MODELS_DIR} --bind ${JOB_DIR} ${container_ref}"

INDEXER_LOG="${JOB_DIR}/rag-indexer.log"
echo "::notice::Starting indexer (docs=${RAG_DOCS_DIR}, table=${RAG_TABLE}, log=${INDEXER_LOG})"
${CONTAINER_RUN} python3 "${SERVICE_DIR}/indexer.py" --poll > "${INDEXER_LOG}" 2>&1 &
INDEXER_PID=$!

# The endpoint teardown kills the foreground tree; the backgrounded indexer
# needs an explicit kill. The generic trap (and script_submitter's cleanup
# path) run this from the script's CWD.
cat > cancel.sh <<EOF
kill ${INDEXER_PID} 2>/dev/null
EOF
chmod +x cancel.sh

sleep 5
if ! kill -0 ${INDEXER_PID} 2>/dev/null; then
    echo "::error title=Indexer died::indexer exited at startup; last log lines follow"
    tail -20 "${INDEXER_LOG}"
    pw workflows runs cancel ${PW_RUN_SLUG}
    exit 1
fi

echo "::notice::Starting search API behind pw endpoint"
# {port} is replaced by pw endpoints run with the local port it forwards to
pw endpoints run ${pw_endpoints_args} -- ${CONTAINER_RUN} python3 "${SERVICE_DIR}/rag_server.py" \
    --port {port} \
    --host 127.0.0.1

if [ $? -ne 0 ]; then
    echo "::error title=Error::pw endpoints command failed"
    # Fail loud: without this, wait_for_endpoint polls forever for an endpoint
    # that will never register
    pw workflows runs cancel ${PW_RUN_SLUG}
    exit 1
fi
