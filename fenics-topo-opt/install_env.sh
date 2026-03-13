#!/usr/bin/env bash
set -o pipefail

################################################################################
# FEniCS Topology Optimization - Conda Environment Installer
#
# Installs miniconda (if needed) and creates/updates a conda environment
# with FEniCS and dashboard dependencies.
#
# Expected variables (from inputs.sh):
#   service_parent_install_dir  (default: ${HOME}/pw/software)
#   service_conda_install_dir   (default: .miniconda3c)
#   service_conda_env           (default: fenics-topo-opt)
################################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir=${HOME}/pw/software
fi
if [ -z "${service_conda_install_dir}" ]; then
    service_conda_install_dir=.miniconda3c
fi
if [ -z "${service_conda_env}" ]; then
    service_conda_env=fenics-topo-opt
fi

CONDA_DIR="${service_parent_install_dir}/${service_conda_install_dir}"
CONDA_SH="${CONDA_DIR}/etc/profile.d/conda.sh"
CONDA_ENV="${service_conda_env}"
CONDA_YAML="${SCRIPT_DIR}/environment.yaml"

f_install_miniconda() {
    local install_dir=$1
    local conda_repo="https://repo.anaconda.com/miniconda/Miniconda3-py312_24.9.2-0-Linux-x86_64.sh"
    local ID=$(date +%s)-${RANDOM}
    echo "$(date) Downloading Miniconda..."
    nohup wget --no-check-certificate ${conda_repo} -O /tmp/miniconda-${ID}.sh 2>&1 > /tmp/miniconda_wget-${ID}.out
    rm -rf ${install_dir}
    mkdir -p $(dirname ${install_dir})
    echo "$(date) Installing Miniconda to ${install_dir}..."
    nohup bash /tmp/miniconda-${ID}.sh -b -p ${install_dir} 2>&1 > /tmp/miniconda_sh-${ID}.out
    source ${install_dir}/etc/profile.d/conda.sh
    conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main
    conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r
}

mkdir -p "${service_parent_install_dir}"

# Remove name/prefix lines from YAML (idempotent)
sed -i -e '/^name:/d' -e '/^prefix:/d' -e '/^$/d' ${CONDA_YAML}

# Install miniconda if not present
if [ ! -d "${CONDA_DIR}" ]; then
    echo "$(date) Conda directory <${CONDA_DIR}> not found. Installing conda..."
    f_install_miniconda "${CONDA_DIR}"
fi

if [ ! -f "${CONDA_SH}" ]; then
    echo "$(date) ERROR: conda.sh not found at ${CONDA_SH}" >&2
    exit 1
fi

echo "$(date) Sourcing Conda SH <${CONDA_SH}>"
source "${CONDA_SH}"

# Create environment if it doesn't exist
if ! conda env list | grep -q "${CONDA_ENV}"; then
    echo "$(date) Creating Conda Environment <${CONDA_ENV}>"
    conda create --name "${CONDA_ENV}" -y
fi

echo "$(date) Activating Conda Environment <${CONDA_ENV}>"
conda activate "${CONDA_ENV}"

echo "$(date) Installing environment from YAML <${CONDA_YAML}>"
conda env update -n "${CONDA_ENV}" -f "${CONDA_YAML}"

# Verify FEniCS is importable
python -c "import dolfin; print('FEniCS version:', dolfin.__version__)" || {
    echo "$(date) ERROR: FEniCS import failed" >&2
    exit 1
}

echo "$(date) Environment setup complete"
