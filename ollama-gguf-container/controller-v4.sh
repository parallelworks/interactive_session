set -o pipefail
set -x

source tools/oras/libs.sh

################################################################################
# Interactive Session Controller - Ollama GGUF (Singularity)
#
# Purpose: Download the Ollama SIF and pull GGUF models from the Ollama
#          library or Hugging Face (hf.co/<owner>/<repo>:<quant>)
# Runs on: Controller node with internet access
# Called by: Workflow preprocessing step
#
# Required Environment Variables:
#   - service_parent_install_dir: Install directory (default: ${HOME}/pw/software)
#   - service_ollama_version: Ollama release tag (default: v0.32.5)
#   - service_models: Space or comma separated model references to pull
################################################################################

if ! [ -z ${PW_PARENT_JOB_DIR} ]; then
    cd ${PW_PARENT_JOB_DIR}
fi

if [ -n "${service_parent_install_dir}" ]; then
    container_sif=${service_parent_install_dir}/containers/ollama-gguf.sif
    if ! [ -f "${container_sif}" ] && ! [ -w "${service_parent_install_dir}" ]; then
        echo "::warning::container_sif ${container_sif} does not exist and no write permission to ${service_parent_install_dir}. Resetting to ${HOME}/pw/software."
        service_parent_install_dir=${HOME}/pw/software
    fi
else
    service_parent_install_dir=${HOME}/pw/software
fi

mkdir -p ${service_parent_install_dir}/containers
chmod a+rX ${service_parent_install_dir}/containers

container_sif=${service_parent_install_dir}/containers/ollama-gguf.sif
sandbox_dir=${service_parent_install_dir}/containers/ollama-gguf-sandbox

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

service_ollama_version=${service_ollama_version:-v0.32.5}

if ! [ -f "${container_sif}" ]; then
    echo "::group::Ollama SIF Download"
    oras_pull_file ghcr.io/parallelworks/ollama-gguf:${service_ollama_version#v} ollama-gguf.sif ${container_sif}
    if [ ! -s ${container_sif} ]; then
        echo "::error title=Error::Failed to download file ${container_sif}"
        exit 1
    fi
    chmod a+r ${container_sif}
    echo "::endgroup::"
fi

# Prefer the SIF; fall back to a sandbox when this node cannot mount it. The
# sandbox lands on the shared filesystem, so the start template can reuse it.
if singularity exec "${container_sif}" /bin/true > /dev/null 2>&1; then
    container_ref="${container_sif}"
else
    echo "::notice::Cannot mount SIF on this node; using sandbox directory"
    export SINGULARITY_TMPDIR=${HOME}/.singularity_tmp
    export SINGULARITY_CACHEDIR=${HOME}/.singularity_cache
    mkdir -p $SINGULARITY_TMPDIR $SINGULARITY_CACHEDIR
    if ! [ -d "${sandbox_dir}" ]; then
        singularity build --fakeroot --force --sandbox "${sandbox_dir}" "${container_sif}"
    fi
    container_ref="${sandbox_dir}"
fi

# Model weights are shared with the native ollama-gguf variant
if [ -z "${service_models_dir}" ]; then
    service_models_dir=${service_parent_install_dir}/ollama-gguf/models
fi
export OLLAMA_MODELS=${service_models_dir}

model_manifest_path() {
    local ref=$1 name=$1 tag=latest
    case "${ref}" in *:*) name=${ref%%:*}; tag=${ref##*:};; esac
    case "${name}" in
        */*/*) echo "${OLLAMA_MODELS}/manifests/${name}/${tag}" ;;
        */*) echo "${OLLAMA_MODELS}/manifests/registry.ollama.ai/${name}/${tag}" ;;
        *) echo "${OLLAMA_MODELS}/manifests/registry.ollama.ai/library/${name}/${tag}" ;;
    esac
}

# Serve only the requested models by over-mounting a filtered manifests
# directory into the container: the store contents define what ollama serves,
# there is no native allowlist
build_manifests_view() {
    if [ "${service_serve_only_requested}" != "true" ]; then
        return 0
    fi
    manifests_view=${PW_PARENT_JOB_DIR}/ollama-manifests-view
    rm -rf ${manifests_view}
    for model in ${service_models//,/ }; do
        src=$(model_manifest_path ${model})
        if ! [ -s "${src}" ]; then
            echo "::error title=Error::manifest for ${model} not found at ${src}"
            exit 1
        fi
        rel=${src#${OLLAMA_MODELS}/manifests/}
        mkdir -p ${manifests_view}/$(dirname ${rel})
        cp ${src} ${manifests_view}/${rel}
    done
    # Pruning would delete shared blobs the filtered manifests do not reference
    echo "export OLLAMA_NOPRUNE=1" >> inputs.sh
    echo "export service_manifests_view=\"${manifests_view}\"" >> inputs.sh
}

need_pull=false
for model in ${service_models//,/ }; do
    if ! [ -s "$(model_manifest_path ${model})" ]; then
        need_pull=true
    fi
done

# Writability of the store, probing the nearest existing ancestor when the
# directory does not exist yet
probe=${OLLAMA_MODELS}
while [ ! -e "${probe}" ]; do probe=$(dirname "${probe}"); done
skip_pull=false
if ! [ -w "${probe}" ]; then
    if [ "${need_pull}" = "true" ]; then
        fallback_dir=${HOME}/pw/software/ollama-gguf/models
        echo "::warning title=Model Directory::Cannot write to ${OLLAMA_MODELS} and some requested models are not cached there; falling back to ${fallback_dir}"
        service_models_dir=${fallback_dir}
        export OLLAMA_MODELS=${fallback_dir}
    else
        echo "::notice title=Model Directory::${OLLAMA_MODELS} is not writable; serving the cached models read-only"
        echo "export OLLAMA_NOPRUNE=1" >> inputs.sh
        export OLLAMA_NOPRUNE=1
        skip_pull=true
    fi
fi
# The start template reads the resolved store from inputs.sh
echo "export service_models_dir=\"${service_models_dir}\"" >> inputs.sh

if [ "${skip_pull}" = "true" ]; then
    build_manifests_view
    exit 0
fi

# Cached models are served as-is: pulling them again rewrites their manifest,
# which fails when another user owns the file in a shared store
if [ "${need_pull}" != "true" ]; then
    echo "::notice title=Model Directory::All requested models are already cached in ${OLLAMA_MODELS}"
    build_manifests_view
    exit 0
fi

echo "::group::Pull Models"
mkdir -p ${OLLAMA_MODELS}
# Model pulls go through a temporary server on an ephemeral port; the weights
# land in the shared-filesystem OLLAMA_MODELS dir for the service to read
export OLLAMA_HOST=127.0.0.1:$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
singularity exec \
    --bind "${service_parent_install_dir}:${service_parent_install_dir}" \
    --bind "${OLLAMA_MODELS}:${OLLAMA_MODELS}" \
    --env OLLAMA_HOST=${OLLAMA_HOST} \
    --env OLLAMA_MODELS=${OLLAMA_MODELS} \
    "${container_ref}" /bin/ollama serve > ollama-controller-serve.log 2>&1 &
server_pid=$!
trap "kill ${server_pid} 2> /dev/null" EXIT

retries=0
until curl -s http://${OLLAMA_HOST}/ > /dev/null; do
    retries=$((retries + 1))
    if [ ${retries} -gt 30 ]; then
        echo "::error title=Error::ollama server did not start; see ollama-controller-serve.log"
        exit 1
    fi
    sleep 1
done

# Pulls resume from partial blobs, so a stalled transfer (ollama can hang on a
# dead connection) is bounded by the timeout and finished by the retry
for model in ${service_models//,/ }; do
    if [ -s "$(model_manifest_path ${model})" ]; then
        echo "::notice::${model} is already cached; skipping pull"
        continue
    fi
    echo "::notice::Pulling ${model}"
    pulled=false
    for attempt in 1 2 3; do
        if timeout 1800 singularity exec --env OLLAMA_HOST=${OLLAMA_HOST} "${container_ref}" /bin/ollama pull ${model}; then
            pulled=true
            break
        fi
        echo "::warning::Pull attempt ${attempt} for ${model} failed or timed out; retrying"
    done
    if [ "${pulled}" != "true" ]; then
        echo "::error title=Error::failed to pull model ${model}"
        exit 1
    fi
done

# Best-effort group sharing so other users of a shared store can read the
# weights and add models later
chmod -R g+rwX ${OLLAMA_MODELS} 2> /dev/null || true

singularity exec --env OLLAMA_HOST=${OLLAMA_HOST} "${container_ref}" /bin/ollama list
echo "::endgroup::"

build_manifests_view
