if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi


if [ -z "${service_nginx_sif}" ]; then
    service_nginx_sif=${service_parent_install_dir}/nginx-unprivileged.sif
fi

if [ -z "${service_vncserver_sif}" ]; then
    service_vncserver_sif=${service_parent_install_dir}/vncserver.sif
fi


download_and_install_novnc() {
    # 1. Clone the repository with --no-checkout
    export GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null '
    # Needed for emed
    git config --global --unset http.sslbackend
    git clone --no-checkout https://github.com/parallelworks/interactive_session.git

    # 2. Navigate into the repository directory
    cd interactive_session
    #git checkout download-dependencies

    # 3. Initialize sparse-checkout
    git sparse-checkout init

    # 4. Configure sparse-checkout to include only the desired directory
    service_novnc_tgz_repo_path="downloads/vnc/${service_novnc_tgz_basename}"
    echo "${service_novnc_tgz_repo_path}" > .git/info/sparse-checkout

    # 5. Perform the checkout
    git checkout

    # 6. Extract tgz
    tar -zxf ${service_novnc_tgz_repo_path} -C ${service_parent_install_dir}

    # 7. Clean
    cd ../
    rm -rf interactive_session
    
}

download_singularity_container() {
    local repo_path=$1
    local host_path=$2
    # 1. Clone the repository with --no-checkout
    export GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null '
    # Needed for emed
    git config --global --unset http.sslbackend
    git clone --no-checkout https://github.com/parallelworks/interactive_session.git

    # 2. Navigate into the repository directory
    cd interactive_session
    #git checkout download-dependencies

    # 3. Initialize sparse-checkout
    git sparse-checkout init

    # 4. Configure sparse-checkout to include only the desired file
    echo ${repo_path} > .git/info/sparse-checkout

    # 5. Perform the checkout
    git checkout

    # 6. Extract tgz
    mv ${repo_path} ${host_path}

    # 7. Clean
    cd ../
    rm -rf interactive_session    
}

displayErrorMessage() {
    echo $(date): $1
}

echo; echo

mkdir -p ${service_parent_install_dir}

service_novnc_tgz_stem=$(echo ${service_novnc_tgz_basename} | sed "s|.tar.gz||g" | sed "s|.tgz||g")
service_novnc_install_dir=${service_parent_install_dir}/${service_novnc_tgz_stem}

if ! [ -d "${service_novnc_install_dir}" ]; then
    echo "Downloading and installing ${service_novnc_install_dir}"
    download_and_install_novnc
fi

# Download nginx singularity container
if ! [ -f "${service_nginx_sif}" ]; then
    echo; echo "Downloading nginx singularity from Github"
    download_singularity_container downloads/jupyter/nginx-unprivileged.sif ${service_nginx_sif}
fi

if ! [ -d "${service_novnc_install_dir}" ]; then
    echo
    displayErrorMessage "Failed to install ${service_novnc_install_dir}"
    exit 1
fi

# Download vnserver container if vncserver is missing
if [[ "${HOSTNAME}" == gaea* && -f /usr/lib/vncserver ]]; then
    export service_vnc_exec=/usr/lib/vncserver
fi

# The reason we need service_download_vncserver_container is:
# - vncserver can be installed in the compute nodes but not in the controlle nodes
# - Some compute nodes don't have access to the internet
if [[ ${service_download_vncserver_container} == "true" ]]; then
    if ! [ -f ${service_vncserver_sif} ]; then
        wget -O ${service_vncserver_sif} https://github.com/parallelworks/interactive_session/raw/vncserver-singularity/downloads/vnc/vncserver.sif
    fi
    if ! [ -f ${service_vncserver_sif} ]; then
        echo "$(date) ERROR: Failed to download file ${service_vncserver_sif}"
        exit 1
    fi
    chmod +x ${service_vncserver_sif}
fi
