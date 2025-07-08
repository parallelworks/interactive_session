if [ -z ${service_novnc_parent_install_dir} ]; then
    service_novnc_parent_install_dir=${HOME}/pw/software
fi

download_and_install() {
    # 1. Clone the repository with --no-checkout
    export GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null '
    # Needed for emed
    git config --global --unset http.sslbackend
    git clone --no-checkout https://github.com/parallelworks/interactive_session.git

    # 2. Navigate into the repository directory
    cd interactive_session

    # 3. Initialize sparse-checkout
    git sparse-checkout init

    # 4. Configure sparse-checkout to include both desired paths
    echo "downloads/jupyter/nginx-unprivileged.sif" > .git/info/sparse-checkout
    service_novnc_tgz_repo_path="downloads/vnc/${service_novnc_tgz_basename}"
    echo "${service_novnc_tgz_repo_path}" >> .git/info/sparse-checkout

    # 5. Perform the checkout
    git checkout

    # 6. Extract files
    cp downloads/jupyter/nginx-unprivileged.sif "${service_nginx_sif}"
    tar -zxf "${service_novnc_tgz_repo_path}" -C "${service_novnc_parent_install_dir}"

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