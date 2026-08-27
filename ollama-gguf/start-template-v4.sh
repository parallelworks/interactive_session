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

# hf.co and huggingface.co address the same registry, and sites that filter by
# domain commonly allow the long name while blocking the short one, which
# surfaces as a connection reset rather than a policy message. Prefer whichever
# form is already in the model store, since a cache written under one name is
# invisible under the other and would be re-pulled in full; otherwise take the
# long name, which more sites allow.
if [ -n "${service_models}" ]; then
    normalised_models=""
    for ref in ${service_models//,/ }; do
        short="${ref}"; long="${ref}"
        case "${ref}" in
            hf.co/*) long="huggingface.co/${ref#hf.co/}" ;;
            huggingface.co/*) short="hf.co/${ref#huggingface.co/}" ;;
        esac
        chosen="${long}"
        for candidate in "${ref}" "${short}" "${long}"; do
            name="${candidate}"; tag=latest
            case "${candidate}" in *:*) name="${candidate%%:*}"; tag="${candidate##*:}" ;; esac
            case "${name}" in
                */*/*) manifest="${OLLAMA_MODELS}/manifests/${name}/${tag}" ;;
                */*) manifest="${OLLAMA_MODELS}/manifests/registry.ollama.ai/${name}/${tag}" ;;
                *) manifest="${OLLAMA_MODELS}/manifests/registry.ollama.ai/library/${name}/${tag}" ;;
            esac
            if [ -s "${manifest}" ]; then
                chosen="${candidate}"
                break
            fi
        done
        normalised_models="${normalised_models} ${chosen}"
    done
    service_models="$(echo ${normalised_models} | xargs)"
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
    # pw workflows runs cancel ${PW_RUN_SLUG}
    exit 1
fi
echo "::endgroup::"
