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
    conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main
    conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r
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
    local REPO="parallelworks/interactive_session"
    local BRANCH="main"
    local FILE_PATH="downloads/juice/juice-gpu-linux.tar.gz"
    local OUTPUT_FILE="juice-gpu-linux.tar.gz"
    local RAW_URL="https://raw.githubusercontent.com/$REPO/$BRANCH/$FILE_PATH"
    local LFS_API_URL="https://github.com/$REPO.git/info/lfs/objects/batch"

    # Check for jq dependency
    if ! command -v jq >/dev/null 2>&1; then
        echo "ERROR: jq is required to parse JSON."
        exit 1
    fi

    # Step 1: Download the LFS pointer file
    echo "Fetching LFS pointer file..."
    curl -L -s -o lfs-pointer.txt "$RAW_URL" || {
        echo "ERROR: Failed to download LFS pointer from $RAW_URL"
        exit 1
    }

    # Step 2: Extract oid and size from the pointer file
    if [ ! -s lfs-pointer.txt ]; then
        echo "ERROR: LFS pointer file is empty or not found"
        exit 1
    fi

    OID=$(grep '^oid' lfs-pointer.txt | awk '{print $2}' | cut -d':' -f2)
    SIZE=$(grep '^size' lfs-pointer.txt | awk '{print $2}')

    if [ -z "$OID" ] || [ -z "$SIZE" ]; then
        echo "ERROR: Could not extract oid or size from LFS pointer"
        cat lfs-pointer.txt
        exit 1
    fi

    echo "Found LFS pointer: oid=$OID, size=$SIZE bytes"

    # Step 3: Query LFS API to get the download URL
    echo "Querying LFS API for download URL..."
    curl -L -s -o lfs-response.json "$LFS_API_URL" \
        -H "Accept: application/vnd.git-lfs+json" \
        -H "Content-Type: application/vnd.git-lfs+json" \
        -d "{\"operation\": \"download\", \"transfers\": [\"basic\"], \"objects\": [{\"oid\": \"$OID\", \"size\": $SIZE}]}" || {
        echo "ERROR: Failed to query LFS API"
        exit 1
    }

    # Step 4: Extract the download URL from the JSON response
    DOWNLOAD_URL=$(jq -r '.objects[0].actions.download.href' lfs-response.json 2>/dev/null)
    if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ]; then
        echo "ERROR: Could not extract download URL from LFS API response"
        cat lfs-response.json
        exit 1
    fi

    echo "Found download URL: $DOWNLOAD_URL"

    # Step 5: Download the full file
    echo "Downloading file..."
    curl -L -o "$OUTPUT_FILE" "$DOWNLOAD_URL" || {
        echo "ERROR: Failed to download file from $DOWNLOAD_URL"
        exit 1
    }

    # Step 6: Move file
    mv ${OUTPUT_FILE} ${juice_install_dir}
    
    # Step 7: Extraxct tgz
    cd ${juice_install_dir}
    tar -zxvf ${OUTPUT_FILE}
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
    if [ -z "${service_load_env}" ]; then
        service_load_env="source ${service_conda_sh}; conda activate ${service_conda_env}"
    fi
fi
eval "${service_load_env}"

if [ -z $(which jupyter-lab 2> /dev/null) ]; then
    displayErrorMessage "jupyter-lab command not found"
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