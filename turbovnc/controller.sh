if [ -z ${service_novnc_parent_install_dir} ]; then
    service_novnc_parent_install_dir=${HOME}/pw/software
fi

#service_novnc_tgz_basename=noVNC-1.3.0.tgz

sshusercontainer="ssh ${resource_ssh_usercontainer_options_controller} -f ${USER_CONTAINER_HOST}"

download_and_install() {
    # 1. Clone the repository with --no-checkout
    export GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=no'
    # Needed for emed
    git config --global --unset http.sslbackend
    git clone --no-checkout https://github.com/parallelworks/interactive_session.git

    # 2. Navigate into the repository directory
    cd interactive_session
    git checkout download-dependencies

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
    ${sshusercontainer} "sed -i \"s|.*ERROR_MESSAGE.*|    \\\"ERROR_MESSAGE\\\": \\\"$1\\\"|\" ${PW_JOB_PATH}/service.json"
    ${sshusercontainer} "sed -i \"s|.*JOB_STATUS.*|    \\\"JOB_STATUS\\\": \\\"FAILED\\\",|\" ${PW_JOB_PATH}/service.json"
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