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
#   - service_context_length: Model context window in tokens, or auto or max
#     (default: 8192; max uses service_context_resolved from the controller)
#   - service_keep_alive: How long models stay loaded in memory (default: 5m)
################################################################################

# The controller resolved which install to run and appended it to inputs.sh;
# re-deriving it here is how the two steps end up pointing at different copies.
if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

service_install_dir=${service_parent_install_dir}/ollama-gguf
service_exec=${service_exec:-${service_install_dir}/bin/ollama}

if ! ${service_exec} --version > /dev/null 2>&1; then
    echo "::error title=Error::ollama not found in ${service_install_dir}"
    exit 1
fi

# The controller appends the resolved service_models_dir to inputs.sh
export OLLAMA_MODELS=${service_models_dir:-${service_install_dir}/models}

# The controller resolved the store, picked the hf.co / huggingface.co spelling
# that store actually holds, and exported both service_models and the plain
# names to serve them under, so nothing is re-derived here: two copies of that
# logic disagreeing is how a model ends up served under a name the manifests
# view does not contain.

# The controller also assembled a manifests directory for this run: a filtered
# view where only the requested models are to be served, and in every case the
# plain names those models are served under. ollama has no allowlist and no
# rename at the server, so it is handed a store whose manifests are that
# directory and whose blobs are the real ones.
if [ -n "${service_manifests_view}" ]; then
    serve_store=${PWD}/ollama-store-view
    mkdir -p ${serve_store}
    ln -sfn "${service_manifests_view}" ${serve_store}/manifests
    ln -sfn "${OLLAMA_MODELS}/blobs" ${serve_store}/blobs
    echo "::notice::Serving ${service_served_models:-${service_models}} from the manifests view the controller assembled"
    export OLLAMA_MODELS=${serve_store}
    export OLLAMA_NOPRUNE="${OLLAMA_NOPRUNE:-1}"
fi
# auto leaves OLLAMA_CONTEXT_LENGTH unset so ollama picks its own default,
# which is small; max uses the window the controller read from the model
# metadata, and anything else is the number the operator chose.
if [ "${service_context_length}" = "max" ]; then
    if [ -n "${service_context_resolved}" ]; then
        export OLLAMA_CONTEXT_LENGTH=${service_context_resolved}
    fi
elif [ -n "${service_context_length}" ] && [ "${service_context_length}" != "auto" ]; then
    export OLLAMA_CONTEXT_LENGTH=${service_context_length}
fi
export OLLAMA_KEEP_ALIVE=${service_keep_alive:-5m}

# pw endpoints run exports PORT to the wrapped command; the launcher reads it
# at runtime (it is unknown before launch)
cat > launch-ollama-${PW_JOB_ID}.sh <<EOF
#!/bin/bash
export OLLAMA_HOST="127.0.0.1:\${PORT}"
if [ "${service_preload:-true}" = "true" ]; then
    (
        until curl -s "http://127.0.0.1:\${PORT}/" > /dev/null 2>&1; do sleep 1; done
        for model in ${service_served_models:-${service_models}}; do
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

endpoints_rc=$?

# The workflow cancels this job the moment the endpoint registers, which kills
# the wrapped command and returns non-zero. That is how a successful launch
# ends, not a failure, and calling it an error is why a healthy run shows a red
# step and reads as broken. Only a launch that never registered an endpoint is
# one.
if [ ${endpoints_rc} -ne 0 ]; then
    served_name=$(printf '%s' "${pw_endpoints_args}" | sed -n 's/.*--name[ =]\{1,\}\([^ ]*\).*/\1/p')
    if [ -n "${served_name}" ] && pw endpoints list 2>/dev/null | awk '{print $1}' | grep -qxF "${served_name}"; then
        echo "::notice::Endpoint ${served_name} served until this job was cancelled; exiting cleanly"
        exit 0
    fi
    echo "::error title=Error::pw endpoints command failed"
    # Fail loud: without this, wait_for_endpoint polls forever for an endpoint
    # that will never register
    # pw workflows runs cancel ${PW_RUN_SLUG}
    sleep 3
    exit 1
fi
echo "::endgroup::"
