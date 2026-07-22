set -o pipefail

################################################################################
# Interactive Session Controller - Jupyter Notebook Host
#
# Purpose: Install Jupyter Notebook in a conda environment
# Runs on: Controller node with internet access
# Called by: Workflow preprocessing step
#
# Required Environment Variables:
#   - service_parent_install_dir: Install directory (default: ${HOME}/pw/software)
#   - service_conda_install: Whether to install conda (true/false)
#   - service_conda_install_dir: Conda installation directory name
#   - service_conda_env: Conda environment name
#   - service_install_instructions: latest | yaml | <conda-env-yaml-name>
#   - service_load_env: Command to load jupyter-notebook (when conda_install=false)
################################################################################

if ! [ -z ${PW_PARENT_JOB_DIR} ]; then
    cd ${PW_PARENT_JOB_DIR}
fi

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi
mkdir -p ${service_parent_install_dir}

service_conda_sh=${service_parent_install_dir}/${service_conda_install_dir}/etc/profile.d/conda.sh

f_install_miniconda() {
    install_dir=$1
    if [[ "${service_install_instructions}" == "latest" ]]; then
        echo "::notice::Installing Miniconda3-latest-Linux-x86_64.sh"
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
    # Remove lines starting with name, prefix and remove empty lines
    sed -i -e '/^name:/d' -e '/^prefix:/d' -e '/^$/d' ${CONDA_YAML}

    if [ ! -d "${CONDA_DIR}" ]; then
        echo "::notice::Conda directory <${CONDA_DIR}> not found. Installing conda..."
        f_install_miniconda ${CONDA_DIR}
    fi

    echo "::notice::Sourcing Conda SH <${CONDA_SH}>"
    source ${CONDA_SH}

    if ! conda env list | grep -q "${CONDA_ENV}"; then
        echo "::notice::Creating Conda Environment <${CONDA_ENV}>"
        conda create --name ${CONDA_ENV}
    fi

    echo "::notice::Activating Conda Environment <${CONDA_ENV}>"
    conda activate ${CONDA_ENV}

    echo "::notice::Installing conda environment from YAML"
    conda env update -n ${CONDA_ENV} -f ${CONDA_YAML}
}

if [[ "${service_conda_install}" == "true" ]]; then
    echo "::group::Conda Installation"
    if [[ "${service_install_instructions}" == "install_command" ]]; then
        echo "::notice::Running install command ${service_install_command}"
        eval ${service_install_command}
    elif [[ "${service_install_instructions}" == "yaml" ]]; then
        echo "::notice::Installing custom conda environment"
        printf "%b" "${service_yaml}" > conda.yaml
        cat conda.yaml
        f_set_up_conda_from_yaml ${service_parent_install_dir}/${service_conda_install_dir} ${service_conda_env} conda.yaml
    elif [[ "${service_install_instructions}" == "latest" ]]; then
        echo "::notice::Installing latest conda environment"
        {
            source ${service_conda_sh}
        } || {
            conda_dir=$(echo ${service_conda_sh} | sed "s|etc/profile.d/conda.sh||g" )
            f_install_miniconda ${conda_dir}
            source ${service_conda_sh}
            conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main
            conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r
        }
        {
            eval "conda activate ${service_conda_env}"
        } || {
            conda create -n ${service_conda_env} jupyter -y
            eval "conda activate ${service_conda_env}"
        }
        if [ -z $(which jupyter-notebook 2> /dev/null) ]; then
            conda install conda-forge::jupyter-book -y
            conda install conda-forge::nb_conda_kernels -y
            conda install conda-forge::jinja2 -y
        fi
    else
        echo "::notice::Installing conda environment ${service_install_instructions}.yaml"
        f_set_up_conda_from_yaml ${service_parent_install_dir}/${service_conda_install_dir} ${service_conda_env} ${service_install_instructions}.yaml
    fi
    if [ -z "${service_load_env}" ]; then
        service_load_env="source ${service_conda_sh}; conda activate ${service_conda_env}"
    fi
    echo "::endgroup::"
fi

eval "${service_load_env}"

if [ -z $(which jupyter-notebook 2> /dev/null) ]; then
    echo "::error title=Error::jupyter-notebook command not found"
    exit 1
fi

echo "::notice::Jupyter version:"
jupyter notebook --version

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
