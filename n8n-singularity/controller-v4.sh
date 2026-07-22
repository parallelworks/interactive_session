set -o pipefail
set -x

source tools/oras/libs.sh

mkdir -p "${service_parent_install_dir}" || true
if [ -n "${service_parent_install_dir}" ]; then
    container_sif=${service_parent_install_dir}/containers/n8n.sif
    if ! [ -f "${container_sif}" ] && ! [ -w "${service_parent_install_dir}" ]; then
        echo "::warning::container_sif ${container_sif} does not exist and no write permission to ${service_parent_install_dir}. Resetting to ${HOME}/pw/software."
        service_parent_install_dir=${HOME}/pw/software
    fi
else
    service_parent_install_dir=${HOME}/pw/software
fi

mkdir -p ${service_parent_install_dir}/containers ${service_parent_install_dir}/tools
chmod a+rX ${service_parent_install_dir}/containers ${service_parent_install_dir}/tools

container_sif=${service_parent_install_dir}/containers/n8n.sif

# Create and open up the n8n data directory so the container user can write to it
mkdir -p "${n8n_data_dir}"
chmod 777 "${n8n_data_dir}" -Rf || true

# Download the SIF only when it is not already present (idempotent)
if ! [ -f "${container_sif}" ]; then
    echo "::group::n8n SIF Download"
    echo "::notice::Using GitHub registry to download file"
    oras_pull_file ghcr.io/parallelworks/n8n:2.0 n8n.sif ${container_sif}
    if [ ! -s ${container_sif} ]; then
        echo "::error title=Error::Failed to download file ${container_sif}"
        exit 1
    fi
    chmod a+r ${container_sif}
    echo "::endgroup::"
fi
