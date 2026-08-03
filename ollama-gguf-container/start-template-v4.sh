################################################################################
# Interactive Session Service Starter - Ollama GGUF (Singularity)
#
# Purpose: Serve the pulled GGUF models through Ollama's OpenAI-compatible API
#          on a pw endpoint, running Ollama from the SIF downloaded by
#          controller-v4.sh (sandbox fallback when the node cannot mount SIFs)
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - pw_endpoints_args: Arguments for pw endpoints run (--name, ...)
#   - service_parent_install_dir: Installation directory
#   - service_context_length: Model context window in tokens (default: 8192)
#   - service_keep_alive: How long models stay loaded in memory (default: 5m)
################################################################################

set -x

if [ -n "${service_parent_install_dir}" ]; then
    container_sif=${service_parent_install_dir}/containers/ollama-gguf.sif
    if ! [ -f "${container_sif}" ] && ! [ -w "${service_parent_install_dir}" ]; then
        echo "::warning::container_sif ${container_sif} does not exist and no write permission to ${service_parent_install_dir}. Resetting to ${HOME}/pw/software."
        service_parent_install_dir=${HOME}/pw/software
    fi
else
    service_parent_install_dir=${HOME}/pw/software
fi

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
    echo "::error title=Error::Missing container image ${container_sif}"
    exit 1
fi

# Prefer running the SIF directly; some nodes cannot mount it (no squashfs
# kernel/FUSE support), in which case unpack it once into a sandbox directory
if singularity exec "${container_sif}" /bin/true > /dev/null 2>&1; then
    echo "::notice::SIF image is runnable on this node"
    container_ref="${container_sif}"
else
    echo "::notice::Cannot mount SIF on this node; using sandbox directory"
    export SINGULARITY_TMPDIR=${HOME}/.singularity_tmp
    export SINGULARITY_CACHEDIR=${HOME}/.singularity_cache
    mkdir -p $SINGULARITY_TMPDIR $SINGULARITY_CACHEDIR
    if ! [ -d "${sandbox_dir}" ]; then
        echo "Building ollama sandbox..."
        singularity build --fakeroot --force --sandbox "${sandbox_dir}" "${container_sif}"
    fi
    container_ref="${sandbox_dir}"
fi

# Model weights are shared with the native ollama-gguf variant
export OLLAMA_MODELS=${service_parent_install_dir}/ollama-gguf/models

nv_flag=""
if nvidia-smi -L > /dev/null 2>&1; then
    echo "::notice::NVIDIA GPU detected; enabling --nv"
    nv_flag="--nv"
fi

# Per-job /tmp prevents cross-user permission conflicts on shared nodes
mkdir -p "$PWD/container_tmp"

# pw endpoints run exports PORT to the wrapped command; the launcher reads it
# at runtime (it is unknown before launch)
cat > launch-ollama-${PW_JOB_ID}.sh <<EOF
#!/bin/bash
exec singularity exec ${nv_flag} \\
    --bind "${service_parent_install_dir}:${service_parent_install_dir}" \\
    --bind "${PWD}/container_tmp:/tmp" \\
    --env OLLAMA_HOST="127.0.0.1:\${PORT}" \\
    --env OLLAMA_MODELS="${OLLAMA_MODELS}" \\
    --env OLLAMA_CONTEXT_LENGTH="${service_context_length:-8192}" \\
    --env OLLAMA_KEEP_ALIVE="${service_keep_alive:-5m}" \\
    "${container_ref}" /bin/ollama serve
EOF
chmod +x launch-ollama-${PW_JOB_ID}.sh

# START SERVICE
echo "::group::Start Service"
echo "::notice::Starting ollama: pw endpoints run --openai --rewrite-host=localhost ${pw_endpoints_args}"

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
