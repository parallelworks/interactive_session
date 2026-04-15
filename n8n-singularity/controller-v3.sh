set -o pipefail
set -x

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

container_tgz=${service_parent_install_dir}/n8n.tgz
container_dir=${service_parent_install_dir}/n8n

mkdir -p "${service_parent_install_dir}"

# Create and open up the n8n data directory so the container user can write to it
mkdir -p "${n8n_data_dir}"
chmod 777 "${n8n_data_dir}" -Rf || true

download_oras(){
    VER="1.2.0"
    wget https://github.com/oras-project/oras/releases/download/v${VER}/oras_${VER}_linux_amd64.tar.gz
    mkdir -p ${service_parent_install_dir}/oras
    tar -xvf oras_${VER}_linux_amd64.tar.gz -C ${service_parent_install_dir}/oras
    rm oras_${VER}_linux_amd64.tar.gz
}

oras_pull_file(){
    repo=$1
    repo_path=$2
    host_path=$3
    ${service_parent_install_dir}/oras/oras pull ${repo}
    mv ${repo_path} ${host_path}
}

# Download the container only when it is not already present (idempotent)
if ! [ -d "${container_dir}" ]; then
    echo "::group::n8n Singularity Container Download"
    echo "::notice::Using GitHub registry to download file"
    download_oras
    oras_pull_file ghcr.io/parallelworks/n8n:1.0 n8n.tgz ${container_tgz}
    if [ ! -s ${container_tgz} ]; then
        echo "::error title=Error::Failed to download file ${container_tgz}"
        exit 1
    fi
    if ! tar -xzf ${container_tgz} -C $(dirname ${container_dir}); then
        echo "::error title=Error::Failed to extract ${container_tgz}"
        exit 1
    fi
    chmod -R u+rwX ${container_dir}
    rm ${container_tgz}
    echo "::endgroup::"
fi
