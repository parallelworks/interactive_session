#!/usr/bin/env bash
# start-template-v4.sh — Streamlit via Singularity behind a pw endpoint
#
# Uses the SIF downloaded by controller-v4.sh. Falls back to a sandbox
# directory when the node cannot mount SIF images (no squashfs support).

set -x

echo "::group::Streamlit Service Starting"

streamlit_registry=${streamlit_registry:-ghcr.io/parallelworks/streamlit:1.0}
registry_slug=$(printf '%s' "${streamlit_registry}" | tr -c 'a-zA-Z0-9._-' '_')

if [ -n "${service_parent_install_dir}" ]; then
    container_sif=${service_parent_install_dir}/containers/${registry_slug}/streamlit.sif
    if ! [ -f "${container_sif}" ] && ! [ -w "${service_parent_install_dir}" ]; then
        echo "::warning::container_sif ${container_sif} does not exist and no write permission to ${service_parent_install_dir}. Resetting to ${HOME}/pw/software."
        service_parent_install_dir=${HOME}/pw/software
    fi
else
    service_parent_install_dir=${HOME}/pw/software
fi

container_sif=${service_parent_install_dir}/containers/${registry_slug}/streamlit.sif
sandbox_dir=${service_parent_install_dir}/containers/${registry_slug}/streamlit-sandbox

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

app_script=${app_script:-${PW_PARENT_JOB_DIR}/streamlit-singularity/demo/app.py}
if ! [ -f "${app_script}" ]; then
    echo "::error title=Error::Streamlit app script ${app_script} not found"
    exit 1
fi
app_dir=$(dirname "${app_script}")

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
        echo "Building streamlit sandbox..."
        singularity build --fakeroot --force --sandbox "${sandbox_dir}" "${container_sif}"
    fi
    container_ref="${sandbox_dir}"
fi

echo "::endgroup::"
echo "::group::Starting Streamlit"

# CORS/XSRF checks are disabled because the endpoint proxy forwards the public
# Host header; the endpoint itself already requires platform login
# {port} is replaced by pw endpoints run with the local port it forwards to
pw endpoints run ${pw_endpoints_args} -- singularity exec \
    --writable-tmpfs \
    --bind "${app_dir}:${app_dir}" \
    --bind "${PWD}/container_tmp:/tmp" \
    --pwd "${app_dir}" \
    "${container_ref}" \
    streamlit run "${app_script}" \
    --server.port {port} \
    --server.address localhost \
    --server.headless true \
    --server.enableCORS false \
    --server.enableXsrfProtection false \
    --browser.gatherUsageStats false

if [ $? -ne 0 ]; then
    echo "::error title=Error::pw endpoints command failed"
    # Fail loud: without this, wait_for_endpoint polls forever for an endpoint
    # that will never register
    pw workflows runs cancel ${PW_RUN_SLUG}
    exit 1
fi
echo "::endgroup::"
