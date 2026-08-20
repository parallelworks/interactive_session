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

# hf.co and huggingface.co address the same registry, and sites that filter by
# domain commonly allow the long name while blocking the short one, which
# surfaces as a connection reset rather than a policy message. Normalise every
# reference once, here, so the manifest paths and every later loop agree.
if [ -n "${service_models}" ]; then
    normalised_models=""
    for ref in ${service_models//,/ }; do
        case "${ref}" in
            hf.co/*) ref="huggingface.co/${ref#hf.co/}" ;;
        esac
        normalised_models="${normalised_models} ${ref}"
    done
    service_models="$(echo ${normalised_models} | xargs)"
fi

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

start_temp_server() {
    export OLLAMA_HOST=127.0.0.1:$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
    ${service_exec} serve > ollama-controller-serve.log 2>&1 &
    server_pid=$!
    trap "kill ${server_pid} 2> /dev/null" EXIT
    retries=0
    until curl -s http://${OLLAMA_HOST}/ > /dev/null; do
        retries=$((retries + 1))
        if [ ${retries} -gt 30 ]; then
            echo "::error title=Error::ollama server did not start; see ollama-controller-serve.log"
            return 1
        fi
        sleep 1
    done
}

# "Max" means the largest window the models were trained for, which only the
# model metadata knows. Resolve it here, where a server is available, and hand
# the number to the start template: the service reads OLLAMA_CONTEXT_LENGTH
# once at startup and cannot ask later.
resolve_max_context() {
    [ "${service_context_length}" = "max" ] || return 0
    local best=0 n=""
    for model in ${service_models//,/ }; do
        n=$(${service_exec} show ${model} 2>/dev/null | awk '$1 == "context" && $2 == "length" {print $3; exit}')
        case "${n}" in
            ''|*[!0-9]*) continue ;;
        esac
        [ "${n}" -gt "${best}" ] && best=${n}
    done
    if [ "${best}" -gt 0 ]; then
        echo "::notice title=Context Length::Serving at the model maximum of ${best} tokens"
        echo "export service_context_resolved=${best}" >> inputs.sh
    else
        echo "::warning title=Context Length::Could not read a context length from the model metadata; falling back to the ollama default"
    fi
}

if [ "${skip_pull}" = "true" ]; then
    if [ "${service_context_length}" = "max" ] && start_temp_server; then
        resolve_max_context
    fi
    exit 0
fi

# Cached models are served as-is: pulling them again rewrites their manifest,
# which fails when another user owns the file in a shared store
if [ "${need_pull}" != "true" ]; then
    echo "::notice title=Model Directory::All requested models are already cached in ${OLLAMA_MODELS}"
    if [ "${service_context_length}" = "max" ] && start_temp_server; then
        resolve_max_context
    fi
    exit 0
fi

echo "::group::Pull Models"
mkdir -p ${OLLAMA_MODELS}
# Model pulls go through a temporary server on an ephemeral port; the weights
# land in the shared-filesystem OLLAMA_MODELS dir for the service to read
start_temp_server || exit 1

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

# Best-effort group sharing so other users of a shared store can read the
# weights and add models later
chmod -R g+rwX ${OLLAMA_MODELS} 2> /dev/null || true

resolve_max_context

${service_exec} list
echo "::endgroup::"
