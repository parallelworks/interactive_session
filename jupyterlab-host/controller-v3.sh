#!/usr/bin/env bash
set -eo pipefail

if ! [ -z ${resource_jobdir} ]; then
    cd ${resource_jobdir}
fi

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

f_install_miniconda() {
    install_dir=$1
    if [[ "${service_install_instructions}" == "latest" ]]; then
        echo "Installing Miniconda3-latest-Linux-x86_64.sh"
        conda_repo="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
    else
        conda_repo="https://repo.anaconda.com/miniconda/Miniconda3-py312_24.9.2-0-Linux-x86_64.sh"
    fi
    ID=$(date +%s)-${RANDOM} # This script may run at the same time!
    nohup wget --no-check-certificate ${conda_repo} -O /tmp/miniconda-${ID}.sh 2>&1 > /tmp/miniconda_wget-${ID}.out
    rm -rf ${install_dir}
    mkdir -p $(dirname ${install_dir})
    nohup bash /tmp/miniconda-${ID}.sh -b -p ${install_dir} 2>&1 > /tmp/miniconda_sh-${ID}.out
    source ${install_dir}/etc/profile.d/conda.sh
    conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main
    conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r
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

    # 6. Move
    mv downloads/jupyter/nginx-unprivileged.sif ${service_nginx_sif}

    # 7. Clean
    cd ../
    rm -rf interactive_session
    
}

download_and_install_juice() {
    # Configuration
    local OUTPUT_FILE="juice.tgz"

    # Step 1: Get download URL from JuiceLabs API
    echo "Fetching JuiceLabs download URL..."
    download=$(curl -s 'https://electra.juicelabs.co/v2/public/download/linux' | python3 -c "import sys, json; print(json.load(sys.stdin)['url'])")


    if [ -z "$download" ]; then
        echo "ERROR: Download URL is empty"
        exit 1
    fi
    echo "Found download URL: $download"

    # Step 2: Prepare install directory
    mkdir -p "${juice_install_dir}"
    cd "${juice_install_dir}" || exit 1

    # Step 3: Install prerequisites
    sudo dnf install -y wget libatomic numactl-libs || {
        echo "ERROR: Failed to install dependencies"
        exit 1
    }

    # Step 4: Download Juice agent
    echo "Downloading Juice agent..."
    wget -O "$OUTPUT_FILE" "$download" || {
        echo "ERROR: Failed to download file"
        exit 1
    }

    # Step 5: Extract archive
    echo "Extracting Juice agent..."
    tar -xzvf "$OUTPUT_FILE" || {
        echo "ERROR: Failed to extract $OUTPUT_FILE"
        exit 1
    }

    echo "Juice agent successfully installed in ${juice_install_dir}"
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
        # Update service_load_env to use the correct path after installation
        service_load_env="source ${service_conda_sh}; conda activate ${service_conda_env}"
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
        # Update service_load_env to use the correct path after installation
        service_load_env="source ${service_conda_sh}; conda activate ${service_conda_env}"
    fi
fi
# Always set service_load_env to use the correct conda path if conda was installed
if [[ "${service_conda_install}" == "true" ]]; then
    service_load_env="source ${service_conda_sh}; conda activate ${service_conda_env}"
fi
eval "${service_load_env}"

if [ -z $(which jupyter-lab 2> /dev/null) ]; then
    displayErrorMessage "jupyter-lab command not found"
fi


# Download singularity container if required
if ! [ -f "${service_nginx_sif}" ]; then
    echo; echo "Downloading nginx singularity from Github"
    download_singularity_container
fi

# Juice
if [[ "${juice_use_juice}" == "true" ]]; then
    if [ -z "${juice_exec}" ]; then
        juice_install_dir=${service_parent_install_dir}/juice
        juice_exec=${service_parent_install_dir}/juice/juice
        if ! [ -f ${juice_exec} ]; then
            echo "INFO: Installing Juice"
            mkdir -p ${juice_install_dir}
            download_and_install_juice
        fi
        if ! [ -f ${juice_exec} ]; then
            echo "ERROR: Juice installation failed"
            exit 1
        fi
    fi
fi


if [[ "${service_conda_install}" != "true" ]]; then
    exit 0
fi


if [[ $service_install_kernels == *"julia-kernel"* ]]; then
    if [ -z $(which julia 2> /dev/null) ]; then
        curl -fsSL https://install.julialang.org | sh -s -- -y
        source ~/.bashrc
        source ~/.bash_profile
        julia -e 'using Pkg; Pkg.add("IJulia")'
    fi
fi

if [[ $service_install_kernels == *"R-kernel"* ]]; then
    conda install r-recommended r-irkernel -y
    R -e 'IRkernel::installspec()'
fi
