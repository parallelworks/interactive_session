#!/usr/bin/env bash
# start-template-v4.sh — n8n via Singularity behind a pw endpoint
#
# Uses the SIF downloaded by controller-v4.sh. Falls back to a sandbox
# directory when the node cannot mount SIF images (no squashfs support).

set -x

echo "::group::n8n Service Starting"

if [ -n "${service_parent_install_dir}" ]; then
    container_sif=${service_parent_install_dir}/containers/n8n.sif
    if ! [ -f "${container_sif}" ] && ! [ -w "${service_parent_install_dir}" ]; then
        echo "::warning::container_sif ${container_sif} does not exist and no write permission to ${service_parent_install_dir}. Resetting to ${HOME}/pw/software."
        service_parent_install_dir=${HOME}/pw/software
    fi
else
    service_parent_install_dir=${HOME}/pw/software
fi

container_sif=${service_parent_install_dir}/containers/n8n.sif
sandbox_dir=${service_parent_install_dir}/containers/n8n-sandbox

# Load singularity/apptainer if not already in PATH
if ! which singularity &> /dev/null; then
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

if ! [ -f "${container_sif}" ]; then
    echo "::error title=Error::Missing container image ${container_sif}"
    exit 1
fi

# Unset host env vars that can corrupt the container's Node.js/npm runtime.
# On Cray EX and similar HPC systems, LD_LIBRARY_PATH carries PE paths that
# cause Node to load incompatible native libraries.
unset PYTHONPATH PYTHONHOME PERL5LIB PERLLIB PERL5OPT PYTHONSTARTUP LD_LIBRARY_PATH

# Per-job /tmp prevents cross-user permission conflicts on shared nodes
mkdir -p "$PWD/container_tmp"

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
        echo "Building n8n sandbox..."
        singularity build --fakeroot --force --sandbox "${sandbox_dir}" "${container_sif}"
    fi
    container_ref="${sandbox_dir}"
fi

echo "::endgroup::"
echo "::group::Starting n8n"

# pw endpoints run exports PORT and PW_ENDPOINT_URL to the wrapped command;
# the launcher reads them at runtime (they are unknown before launch)
cat > launch-n8n-${PW_JOB_ID}.sh <<EOF
#!/bin/bash
exec singularity run \\
    --writable-tmpfs \\
    --bind "${n8n_data_dir}:${n8n_data_dir}" \\
    --bind "${PWD}/container_tmp:/tmp" \\
    --env N8N_USER_FOLDER="${n8n_data_dir}" \\
    --env N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=false \\
    --env GENERIC_TIMEZONE=UTC \\
    --env N8N_HOST=localhost \\
    --env N8N_PORT="\${PORT}" \\
    --env N8N_PROTOCOL=http \\
    --env N8N_DIAGNOSTICS_ENABLED=false \\
    --env N8N_VERSION_NOTIFICATIONS_ENABLED=false \\
    --env N8N_EDITOR_BASE_URL="\${PW_ENDPOINT_URL}" \\
    --env WEBHOOK_URL="\${PW_ENDPOINT_URL}" \\
    "${container_ref}"
EOF
chmod +x launch-n8n-${PW_JOB_ID}.sh

pw endpoints run ${pw_endpoints_args} -- ./launch-n8n-${PW_JOB_ID}.sh

if [ $? -ne 0 ]; then
    echo "::error title=Error::pw endpoints command failed"
    # Fail loud: without this, wait_for_endpoint polls forever for an endpoint
    # that will never register
    pw workflows runs cancel ${PW_RUN_SLUG}
    exit 1
fi
echo "::endgroup::"
