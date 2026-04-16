#!/usr/bin/env bash
# start-template-v3.sh — n8n via Singularity (runs on compute node)
#
# Uses the sandbox downloaded by controller-v3.sh.

set -ex

echo "::group::n8n Service Starting (Compute Node)"

if [ -n "${service_parent_install_dir}" ]; then
    container_dir=${service_parent_install_dir}/containers/n8n
    if ! [ -d "${container_dir}" ] && ! [ -w "${service_parent_install_dir}" ]; then
        echo "::warning::container_dir ${container_dir} does not exist and no write permission to ${service_parent_install_dir}. Resetting to ${HOME}/pw/software."
        service_parent_install_dir=${HOME}/pw/software
    fi
else
    service_parent_install_dir=${HOME}/pw/software
fi

container_dir=${service_parent_install_dir}/containers/n8n

# Initialize cancel script
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh

# Load singularity/apptainer if not already in PATH
if ! command -v singularity &> /dev/null; then
    if module load apptainer 2>/dev/null; then
        echo "::notice::Loaded apptainer module"
    elif module load singularity 2>/dev/null; then
        echo "::notice::Loaded singularity module"
    else
        echo "::error title=Error::singularity/apptainer not found in PATH and could not be loaded via module"
        exit 1
    fi
else
    echo "::notice::singularity already available in PATH"
fi

# Unset host env vars that can corrupt the container's Node.js/npm runtime.
# On Cray EX and similar HPC systems, LD_LIBRARY_PATH carries PE paths that
# cause Node to load incompatible native libraries.
unset PYTHONPATH PYTHONHOME PERL5LIB PERLLIB PERL5OPT PYTHONSTARTUP LD_LIBRARY_PATH

# Per-job /tmp prevents cross-user permission conflicts on shared nodes
mkdir -p "$PWD/container_tmp"
echo "rm -rf $PWD/container_tmp" >> cancel.sh

echo "::endgroup::"
echo "::group::Starting n8n"

set -x
singularity run \
    --writable-tmpfs \
    --bind "${n8n_data_dir}:${n8n_data_dir}" \
    --bind "$PWD/container_tmp:/tmp" \
    --env N8N_USER_FOLDER="${n8n_data_dir}" \
    --env N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=false \
    --env GENERIC_TIMEZONE=UTC \
    --env N8N_HOST=localhost \
    --env N8N_PORT="${service_port}" \
    --env N8N_PROTOCOL=http \
    --env N8N_DIAGNOSTICS_ENABLED=false \
    --env N8N_VERSION_NOTIFICATIONS_ENABLED=false \
    --env N8N_PATH="${basepath}" \
    --env "N8N_EDITOR_BASE_URL=https://activate.parallel.works${basepath}" \
    --env "WEBHOOK_URL=https://activate.parallel.works${basepath}" \
    "${container_dir}" > n8n.log 2>&1 &

n8n_pid=$!
set +x

echo "kill ${n8n_pid} #n8n" >> cancel.sh
echo "::endgroup::"

echo "::group::n8n logs"
tail -f n8n.log &
logs_pid=$!
echo "kill ${logs_pid} #n8n-logs" >> cancel.sh
echo "::endgroup::"

echo "::notice::n8n is up → http://localhost:${service_port}${basepath}"

sleep inf
