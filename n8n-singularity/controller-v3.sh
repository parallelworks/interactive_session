set -o pipefail
set -x

cleanup() {
    if [ -d tools/oras ]; then
        echo "Removing tools/oras"
        rm -rf tools/oras
    fi
}
trap cleanup EXIT

source tools/oras/libs.sh

if [ -n "${service_parent_install_dir}" ]; then
    container_dir=${service_parent_install_dir}/containers/n8n
    if ! [ -d "${container_dir}" ] && ! [ -w "${service_parent_install_dir}" ]; then
        echo "::warning::container_dir ${container_dir} does not exist and no write permission to ${service_parent_install_dir}. Resetting to ${HOME}/pw/software."
        service_parent_install_dir=${HOME}/pw/software
    fi
else
    service_parent_install_dir=${HOME}/pw/software
fi

mkdir -p ${service_parent_install_dir}/containers ${service_parent_install_dir}/tools
chmod a+rX ${service_parent_install_dir}/containers ${service_parent_install_dir}/tools

container_dir=${service_parent_install_dir}/containers/n8n
container_tgz=${container_dir}.tgz


# Create and open up the n8n data directory so the container user can write to it
mkdir -p "${n8n_data_dir}"
chmod 777 "${n8n_data_dir}" -Rf || true

# Download the container only when it is not already present (idempotent)
if ! [ -d "${container_dir}" ]; then
    echo "::group::n8n Singularity Container Download"
    echo "::notice::Using GitHub registry to download file"
    oras_pull_file ghcr.io/parallelworks/n8n:1.0 n8n.tgz ${container_tgz}
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
