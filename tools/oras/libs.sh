

download_oras(){
    if [ -x "${service_parent_install_dir}/tools/oras/oras" ]; then
        return
    fi
    VER="1.2.0"
    wget --no-check-certificate https://github.com/oras-project/oras/releases/download/v${VER}/oras_${VER}_linux_amd64.tar.gz || \
        { echo "::error title=Error::wget failed to download oras v${VER}"; exit 1; }
    if [ ! -f "oras_${VER}_linux_amd64.tar.gz" ]; then
        echo "::error title=Error::Failed to download oras v${VER}"
        exit 1
    fi
    mkdir -p ${service_parent_install_dir}/tools/oras
    tar -xvf oras_${VER}_linux_amd64.tar.gz -C ${service_parent_install_dir}/tools/oras
    chmod -R a+rX ${service_parent_install_dir}/tools/oras
    rm oras_${VER}_linux_amd64.tar.gz
}

oras_pull_file(){
    repo=$1
    repo_path=$2
    host_path=$3
    #if ! ${service_parent_install_dir}/tools/oras/oras pull ${repo}; then
    if ! ./tools/oras/oras pull ${repo}; then
        echo "::error title=Error::oras pull failed for ${repo}"
        exit 1
    fi
    mv ${repo_path} ${host_path}
}
