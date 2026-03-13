set -o pipefail

################################################################################
# Interactive Session Controller - FEniCS Topology Optimization
#
# Purpose: Install conda environment with FEniCS + dashboard dependencies
# Runs on: Controller node with internet access
# Called by: Workflow preprocessing step
################################################################################

if ! [ -z ${PW_PARENT_JOB_DIR} ]; then
    cd ${PW_PARENT_JOB_DIR}
fi

if [[ "${service_conda_install}" != "true" ]]; then
    echo "$(date) Skipping conda installation (service_conda_install=${service_conda_install})"
    exit 0
fi

SCRIPT_DIR=${PW_PARENT_JOB_DIR}/fenics-topo-opt

bash ${SCRIPT_DIR}/install_env.sh
