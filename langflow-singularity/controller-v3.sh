#!/usr/bin/env bash
set -o pipefail
set -x

################################################################################
# Interactive Session Controller - Langflow (Singularity)
#
# Purpose: Download the Langflow Singularity sandbox from GHCR and prepare the
#          data directory. The sandbox is shared across sessions on the same
#          cluster so the download only happens once.
# Runs on: Controller/login node (has internet access)
# Called by: Workflow preprocessing step
#
# Required Environment Variables:
#   - service_parent_install_dir: Install root (default: ${HOME}/pw/software)
#   - service_langflow_data_dir:  Langflow data dir (default: ${HOME}/pw/.langflow)
################################################################################

source ${${PW_PARENT_JOB_DIR}}/tools/oras/libs.sh

mkdir -p "${service_parent_install_dir}" || true
if [ -n "${service_parent_install_dir}" ]; then
    container_dir=${service_parent_install_dir}/containers/langflow
    if ! [ -d "${container_dir}" ] && ! [ -w "${service_parent_install_dir}" ]; then
        echo "::warning::container_dir ${container_dir} does not exist and no write permission to ${service_parent_install_dir}. Resetting to ${HOME}/pw/software."
        service_parent_install_dir=${HOME}/pw/software
    fi
else
    service_parent_install_dir=${HOME}/pw/software
fi

mkdir -p ${service_parent_install_dir}/containers ${service_parent_install_dir}/tools
chmod a+rX ${service_parent_install_dir}/containers ${service_parent_install_dir}/tools

container_dir=${service_parent_install_dir}/containers/langflow
container_tgz=${container_dir}.tgz

# Create and open up the Langflow data directory so the container user can write to it
mkdir -p "${service_langflow_data_dir:-${HOME}/pw/.langflow}"
chmod 777 "${service_langflow_data_dir:-${HOME}/pw/.langflow}" -Rf || true

# Download the container only when it is not already present (idempotent)
if ! [ -d "${container_dir}" ]; then
    echo "::group::Langflow Singularity Container Download"
    echo "::notice::Using GitHub registry to download file"
    oras_pull_file ghcr.io/parallelworks/langflow:1.0 langflow.tgz ${container_tgz}
    if [ ! -s ${container_tgz} ]; then
        echo "::error title=Error::Failed to download file ${container_tgz}"
        exit 1
    fi
    if ! tar -xzf ${container_tgz} -C $(dirname ${container_dir}); then
        echo "::error title=Error::Failed to extract ${container_tgz}"
        exit 1
    fi
    chmod -R a+rX ${container_dir}
    rm ${container_tgz}
    echo "::endgroup::"
fi

echo "::notice::Langflow container ready at ${container_dir}"

# ── Optional: Langflow proxy Python environment ────────────────────────────────
# When ${langflow_proxy_dir} is set (combined LibreChat + Langflow workflow), build
# a venv with the proxy's dependencies so the start script can launch the
# OpenAI-compatible proxy alongside Langflow. The proxy CODE lives at
# ${langflow_proxy_dir} and is intentionally NOT shipped in this repo.
if [ "${langflow_enable_proxy}" = "true" ] && [ -n "${langflow_proxy_dir}" ]; then
    if [ ! -d "${langflow_proxy_dir}/langflow_proxy" ]; then
        echo "::warning::langflow_proxy_dir='${langflow_proxy_dir}' has no 'langflow_proxy' package — proxy will be skipped at start."
    else
        proxy_venv="${service_parent_install_dir}/tools/langflow_proxy_venv"
        if [ ! -x "${proxy_venv}/bin/python" ]; then
            echo "::group::Langflow proxy venv setup"
            python3 -m venv "${proxy_venv}"
            # requirements.txt is an editable self-install (-e .) which needs write
            # access to the code dir; install the declared deps directly instead.
            "${proxy_venv}/bin/pip" install --quiet --upgrade pip
            "${proxy_venv}/bin/pip" install --quiet fastapi uvicorn pydantic aiohttp pyyaml
            echo "::endgroup::"
        fi
        echo "::notice::Langflow proxy venv ready at ${proxy_venv}"
    fi
fi
