set -o pipefail

################################################################################
# Interactive Session Controller - Ollama GGUF
#
# Purpose: Install Ollama and pull GGUF models from the Ollama library or
#          Hugging Face (hf.co/<owner>/<repo>:<quant>)
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

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

service_install_dir=${service_parent_install_dir}/ollama-gguf
service_exec=${service_install_dir}/bin/ollama

if ! ${service_exec} --version > /dev/null 2>&1; then
    echo "::group::Ollama Installation"
    mkdir -p ${service_install_dir}
    tarball=ollama-linux-amd64.tar.zst
    url=https://github.com/ollama/ollama/releases/download/${service_ollama_version:-v0.32.5}/${tarball}
    echo "::notice::Downloading ${url}"
    curl -fsSL -o ${service_install_dir}/${tarball} ${url}
    tar --use-compress-program=unzstd -xf ${service_install_dir}/${tarball} -C ${service_install_dir}
    rm -f ${service_install_dir}/${tarball}
    echo "::endgroup::"
fi

if ! ${service_exec} --version; then
    echo "::error title=Error::ollama installation failed"
    exit 1
fi

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
    exit 0
fi

echo "::group::Pull Models"
mkdir -p ${OLLAMA_MODELS}
# Model pulls go through a temporary server on an ephemeral port; the weights
# land in the shared-filesystem OLLAMA_MODELS dir for the service to read
export OLLAMA_HOST=127.0.0.1:$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
${service_exec} serve > ollama-controller-serve.log 2>&1 &
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
        if timeout 1800 ${service_exec} pull ${model}; then
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

${service_exec} list
echo "::endgroup::"
