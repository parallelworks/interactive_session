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
export OLLAMA_MODELS=${service_install_dir}/models

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

for model in ${service_models//,/ }; do
    echo "::notice::Pulling ${model}"
    if ! ${service_exec} pull ${model}; then
        echo "::error title=Error::failed to pull model ${model}"
        exit 1
    fi
done

${service_exec} list
echo "::endgroup::"
