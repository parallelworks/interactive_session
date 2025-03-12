cd ${resource_jobdir}

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

export AIRFLOW_HOME=${service_airflow_home}
service_conda_install_dir=${service_parent_install_dir}/miniconda3-$(basename ${service_airflow_home})

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



if [[ "${service_conda_install}" == "true" ]]; then
    
    if [[ "${service_install_instructions}" == "install_command" ]]; then
        echo "Running install command ${service_install_command}"
        eval ${service_install_command}
    elif [[ "${service_install_instructions}" == "yaml" ]]; then
        echo "Installing custom conda environment"
        printf "%b" "${service_yaml}" > conda.yaml
        cat conda.yaml
        f_set_up_conda_from_yaml ${service_parent_install_dir}/${service_conda_install_dir} ${service_conda_env} conda.yaml
    elif [[ "${service_install_instructions}" == "latest" ]]; then
        echo "Installing latest"
        {
            source ${service_conda_sh}
        } || {
            conda_dir=$(echo ${service_conda_sh} | sed "s|etc/profile.d/conda.sh||g" )
            f_install_miniconda ${conda_dir}
            source ${service_conda_sh}
        }
        {
            eval "conda activate ${service_conda_env}"
        } || {
            conda create -n ${service_conda_env} jupyter -y
            eval "conda activate ${service_conda_env}"
        }
        if [ -z $(which jupyter-lab 2> /dev/null) ]; then
            conda install -c conda-forge jupyterlab -y
            conda install nb_conda_kernels -y
            conda install -c anaconda jinja2 -y
            pip install ipywidgets
            # Check if SLURM is installed
            if command -v sinfo &> /dev/null; then
                # SLURM extension for Jupyter Lab https://github.com/NERSC/jupyterlab-slurm
                pip install jupyterlab_slurm
            fi
        fi
    else
        echo "Installing conda environment ${service_install_instructions}.yaml"
        f_set_up_conda_from_yaml ${service_parent_install_dir}/${service_conda_install_dir} ${service_conda_env} ${service_install_instructions}.yaml
    fi
    if [ -z ${service_load_env} ]; then
        service_load_env="source ${service_conda_sh}; conda activate ${service_conda_env}"
    fi
fi
eval "${service_load_env}"


# Download singularity container if required
if ! [ -f "${service_nginx_sif}" ]; then
    echo; echo "Downloading nginx singularity from Github"
    download_singularity_container
fi


if [ -d "${AIRFLOW_HOME}" ]; then
    echo "Airflow home directory ${AIRFLOW_HOME} already exists."
    echo "No additional installation is required."
    echo "To reinstall Airflow, delete the directory and rerun the job."
    exit 0
fi

echo; echo "Installing Miniconda under ${service_conda_install_dir}"
mkdir -p ${service_conda_install_dir}
wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O ${service_conda_install_dir}/miniconda.sh
bash ${service_conda_install_dir}/miniconda.sh -b -u -p ${service_conda_install_dir}
rm ${service_conda_install_dir}/miniconda.sh
source ${service_conda_install_dir}/bin/activate


echo; echo "Installing Airflow version ${service_airflow_version}"
AIRFLOW_VERSION=${service_airflow_version}
# Extract the version of Python you have installed. If you're currently using a Python version that is not supported by Airflow, you may want to set this manually.
# See above for supported versions.
PYTHON_VERSION="$(python -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
CONSTRAINT_URL="https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PYTHON_VERSION}.txt"
# For example this would install 2.10.5 with python 3.8: https://raw.githubusercontent.com/apache/airflow/constraints-2.10.5/constraints-3.8.txt
pip install "apache-airflow==${AIRFLOW_VERSION}" --constraint "${CONSTRAINT_URL}"