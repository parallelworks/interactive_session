cd ${resource_jobdir}


if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

service_conda_sh=${service_parent_install_dir}/${service_conda_install_dir}/etc/profile.d/conda.sh
if [ -z "${service_nginx_sif}" ]; then
    service_nginx_sif=${service_parent_install_dir}/nginx-unprivileged.sif
fi


displayErrorMessage() {
    echo $(date): $1
    exit 1
}



download_singularity_container() {
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
    echo downloads/jupyter/nginx-unprivileged.sif > .git/info/sparse-checkout

    # 5. Perform the checkout
    git checkout

    # 6. Extract tgz
    cp downloads/jupyter/nginx-unprivileged.sif ${service_nginx_sif}

    # 7. Clean
    cd ../
    rm -rf interactive_session
    
}

# Download singularity container if required
if ! [ -f "${service_nginx_sif}" ]; then
    echo; echo "Downloading nginx singularity from Github"
    download_singularity_container
fi
