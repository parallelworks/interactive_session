
sshusercontainer="ssh ${resource_ssh_usercontainer_options_controller} -f ${USER_CONTAINER_HOST}"


displayErrorMessage() {
    echo $(date): $1
    ${sshusercontainer} "sed -i \"s|.*ERROR_MESSAGE.*|    \\\"ERROR_MESSAGE\\\": \\\"$1\\\"|\" /pw/jobs/desktop_noaa/00022/service.json"
    ${sshusercontainer} "sed -i \"s|.*JOB_STATUS.*|    \\\"JOB_STATUS\\\": \\\"FAILED\\\",|\" /pw/jobs/desktop_noaa/00022/service.json"
    exit 1
}


f_install_miniconda() {
    install_dir=$1
    echo "Installing Miniconda3-latest-Linux-x86_64.sh"
    conda_repo="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
    ID=$(date +%s)-${RANDOM} # This script may run at the same time!
    nohup wget --no-check-certificate ${conda_repo} -O /tmp/miniconda-${ID}.sh 2>&1 > /tmp/miniconda_wget-${ID}.out
    rm -rf ${install_dir}
    mkdir -p $(dirname ${install_dir})
    nohup bash /tmp/miniconda-${ID}.sh -b -p ${install_dir} 2>&1 > /tmp/miniconda_sh-${ID}.out
}

f_set_up_conda_from_yaml() {
    CONDA_DIR=$1
    CONDA_ENV=$2
    CONDA_YAML=$3
    CONDA_SH="${CONDA_DIR}/etc/profile.d/conda.sh"
    # conda env export
    # Remove line starting with name, prefix and remove empty lines
    sed -i -e '/^name:/d' -e '/^prefix:/d' -e '/^$/d' ${CONDA_YAML} 
    
    if [ ! -d "${CONDA_DIR}" ]; then
        echo "Conda directory <${CONDA_DIR}> not found. Installing conda..."
        f_install_miniconda ${CONDA_DIR}
    fi
    
    echo "Sourcing Conda SH <${CONDA_SH}>"
    source ${CONDA_SH}

    # Check if Conda environment exists
    if ! conda env list | grep -q "${CONDA_ENV}"; then
        echo "Creating Conda Environment <${CONDA_ENV}>"
        conda create --name ${CONDA_ENV}
    fi
    
    echo "Activating Conda Environment <${CONDA_ENV}>"
    conda activate ${CONDA_ENV}
    
    echo "Installing condda environment from YAML"
    conda env update -n ${CONDA_ENV} -f ${CONDA_YAML}
}

if [[ "${service_conda_install}" == "true" ]]; then
    service_conda_dir=$(echo "${service_conda_sh}" | sed 's|/etc/profile.d/conda.sh||')

    if [[ "${service_install_instructions}" == "yaml" ]]; then
        printf "%b" "${service_yaml}" > conda.yaml
        f_set_up_conda_from_yaml ${service_conda_dir} ${service_conda_env} conda.yaml
    elif [[ "${service_install_instructions}" == "dask" ]]; then
        rsync -avzq -e "ssh ${resource_ssh_usercontainer_options_controller}" usercontainer:${pw_job_dir}/${service_name}/dask-extension-jupyterlab.yaml conda.yaml
        f_set_up_conda_from_yaml ${service_conda_dir} ${service_conda_env} conda.yaml
    elif [[ "${service_install_instructions}" == "latest" ]]; then
    
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
            conda create -n ${service_conda_env}
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
        rsync -avzq -e "ssh ${resource_ssh_usercontainer_options_controller}" usercontainer:${pw_job_dir}/${service_name}/${service_install_instructions}.yaml conda.yaml
        f_set_up_conda_from_yaml ${service_conda_dir} ${service_conda_env} conda.yaml
    fi
else
    eval "${service_load_env}"
fi

if [ -z $(which jupyter-lab 2> /dev/null) ]; then
    displayErrorMessage "jupyter-lab command not found"
fi