if [ -z ${service_novnc_parent_install_dir} ]; then
    service_novnc_parent_install_dir=${HOME}/pw/software
fi

#service_novnc_tgz_basename=noVNC-1.3.0.tgz

download_and_install() {
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
    tar -zxf ${service_novnc_tgz_repo_path} -C ${service_novnc_parent_install_dir}

    # 7. Clean
    cd ../
    rm -rf interactive_session
    
}

displayErrorMessage() {
    echo $(date): $1
}

echo; echo

mkdir -p ${service_novnc_parent_install_dir}

service_novnc_tgz_stem=$(echo ${service_novnc_tgz_basename} | sed "s|.tar.gz||g" | sed "s|.tgz||g")
service_novnc_install_dir=${service_novnc_parent_install_dir}/${service_novnc_tgz_stem}

if ! [ -d "${service_novnc_install_dir}" ]; then
    echo "Downloading and installing ${service_novnc_install_dir}"
    download_and_install
fi

if ! [ -d "${service_novnc_install_dir}" ]; then
    echo
    displayErrorMessage "Failed to install ${service_novnc_install_dir}"
    exit 1
fi


# Check if the file exists
if ! [ -f "${service_novnc_install_dir}/ttyd.x86_64" ]; then
    echo
    displayErrorMessage "Missing file ${service_novnc_install_dir}/ttyd.x86_64"
    exit 1
else
    chmod +x "${service_novnc_install_dir}/ttyd.x86_64" 
fi