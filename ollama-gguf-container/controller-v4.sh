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

echo "::group::Pull Models"
# Model weights are shared with the native ollama-gguf variant
export OLLAMA_MODELS=${service_parent_install_dir}/ollama-gguf/models
mkdir -p ${OLLAMA_MODELS}
# Model pulls go through a temporary server on an ephemeral port; the weights
# land in the shared-filesystem OLLAMA_MODELS dir for the service to read
export OLLAMA_HOST=127.0.0.1:$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
singularity exec \
    --bind "${service_parent_install_dir}:${service_parent_install_dir}" \
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

singularity exec --env OLLAMA_HOST=${OLLAMA_HOST} "${container_ref}" /bin/ollama list
echo "::endgroup::"
