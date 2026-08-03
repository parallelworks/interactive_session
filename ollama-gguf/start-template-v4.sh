################################################################################
# Interactive Session Service Starter - Ollama GGUF
#
# Purpose: Serve the pulled GGUF models through Ollama's OpenAI-compatible API
#          on a pw endpoint registered in the platform chat and AI providers
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - pw_endpoints_args: Arguments for pw endpoints run (--name, ...)
#   - service_parent_install_dir: Installation directory
#   - service_context_length: Model context window in tokens (default: 8192)
#   - service_keep_alive: How long models stay loaded in memory (default: 5m)
################################################################################

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

service_install_dir=${service_parent_install_dir}/ollama-gguf
service_exec=${service_install_dir}/bin/ollama

if ! ${service_exec} --version > /dev/null 2>&1; then
    echo "::error title=Error::ollama not found in ${service_install_dir}"
    exit 1
fi

# The controller appends the resolved service_models_dir to inputs.sh
export OLLAMA_MODELS=${service_models_dir:-${service_install_dir}/models}
export OLLAMA_CONTEXT_LENGTH=${service_context_length:-8192}
export OLLAMA_KEEP_ALIVE=${service_keep_alive:-5m}

# pw endpoints run exports PORT to the wrapped command; the launcher reads it
# at runtime (it is unknown before launch)
cat > launch-ollama-${PW_JOB_ID}.sh <<EOF
#!/bin/bash
export OLLAMA_HOST="127.0.0.1:\${PORT}"
if [ "${service_preload:-true}" = "true" ]; then
    (
        until curl -s "http://127.0.0.1:\${PORT}/" > /dev/null 2>&1; do sleep 1; done
        for model in ${service_models//,/ }; do
            echo "Preloading \${model}"
            curl -s "http://127.0.0.1:\${PORT}/api/generate" -d "{\"model\": \"\${model}\"}" > /dev/null
        done
    ) &
fi
exec ${service_exec} serve
EOF
chmod +x launch-ollama-${PW_JOB_ID}.sh

# START SERVICE
echo "::group::Start Service"
echo "::notice::Starting ollama: pw endpoints run --openai --rewrite-host=localhost ${pw_endpoints_args}"

set -x
# --openai registers the endpoint as an OpenAI-compatible provider in the
# platform chat; --rewrite-host satisfies ollama's Host header guard.
pw endpoints run --openai --rewrite-host=localhost ${pw_endpoints_args} -- ./launch-ollama-${PW_JOB_ID}.sh

if [ $? -ne 0 ]; then
    echo "::error title=Error::pw endpoints command failed"
    # Fail loud: without this, wait_for_endpoint polls forever for an endpoint
    # that will never register
    pw workflows runs cancel ${PW_RUN_SLUG}
    exit 1
fi
echo "::endgroup::"
