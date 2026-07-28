

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
    local output_dir tmp_dir
    output_dir=$(dirname ${host_path})
    # Pull into a temp dir on the same filesystem and move into place: pulling
    # straight to host_path leaves a truncated file behind when the download is
    # interrupted, and later runs trust any existing file (observed on HSP as a
    # 12MB stump of an 880MB SIF that failed every mount and sandbox build).
    tmp_dir=$(mktemp -d ${output_dir}/.oras-pull-XXXXXX)
    if ! ${PW_PARENT_JOB_DIR}/tools/oras/oras pull ${repo} -o ${tmp_dir}; then
        rm -rf ${tmp_dir}
        echo "::error title=Error::oras pull failed for ${repo}"
        exit 1
    fi
    if ! mv ${tmp_dir}/${repo_path} ${host_path}; then
        rm -rf ${tmp_dir}
        echo "::error title=Error::${repo} did not contain ${repo_path}"
        exit 1
    fi
    # Keep any extra files the artifact shipped alongside repo_path
    mv ${tmp_dir}/* ${output_dir}/ 2>/dev/null || true
    rm -rf ${tmp_dir}
}

oras_expected_size(){
    # Size of the largest layer in the artifact manifest (our artifacts are
    # single-file, so that layer is the file). Empty output on fetch failure.
    ${PW_PARENT_JOB_DIR}/tools/oras/oras manifest fetch $1 2>/dev/null \
        | grep -o '"size": *[0-9]*' | grep -o '[0-9]*$' | sort -n | tail -1
}
