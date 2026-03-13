################################################################################
# Interactive Session Service Starter - FEniCS Topology Optimization
#
# Purpose: Launch SIMP topology optimization simulation and dashboard
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - service_port: Allocated port (from session_runner)
#   - service_parent_install_dir: Installation directory
#   - service_conda_install_dir:  Conda install dir name
#   - service_conda_env:          Conda environment name
#   - service_conda_install:      Whether conda was installed (true/false)
#   - service_load_env:           Command to load environment (when conda_install=false)
#   - service_nelx, service_nely: Mesh resolution
#   - service_volfrac:            Volume fraction
#   - service_penal:              Penalization exponent
#   - service_num_iterations:     Maximum iterations
#   - service_load_type:          Load/BC type
################################################################################

SCRIPT_DIR=${PW_PARENT_JOB_DIR}/fenics-topo-opt

if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir=${HOME}/pw/software
fi
if [ -z "${service_conda_install_dir}" ]; then
    service_conda_install_dir=.miniconda3c
fi
if [ -z "${service_conda_env}" ]; then
    service_conda_env=fenics-topo-opt
fi

# Activate conda environment
service_conda_sh=${service_parent_install_dir}/${service_conda_install_dir}/etc/profile.d/conda.sh

if [[ "${service_conda_install}" == "true" ]]; then
    source ${service_conda_sh}
    conda activate ${service_conda_env}
else
    eval "${service_load_env}"
fi

if [ -z "$(which python 2>/dev/null)" ]; then
    echo "$(date) ERROR: python not found in PATH" >&2
    exit 1
fi

# Results directory
RESULTS_DIR=${PW_PARENT_JOB_DIR}/results
mkdir -p ${RESULTS_DIR}

# Create cancel.sh
echo '#!/bin/bash' > ${PW_PARENT_JOB_DIR}/cancel.sh
chmod +x ${PW_PARENT_JOB_DIR}/cancel.sh

# Set defaults for simulation parameters
: ${service_nelx:=120}
: ${service_nely:=60}
: ${service_volfrac:=0.5}
: ${service_penal:=3.0}
: ${service_num_iterations:=100}
: ${service_load_type:=cantilever}

# Start topology optimization in background
echo "$(date) Starting topology optimization: nelx=${service_nelx} nely=${service_nely} volfrac=${service_volfrac} penal=${service_penal} load=${service_load_type}"

python ${SCRIPT_DIR}/topo_opt.py \
    --nelx ${service_nelx} \
    --nely ${service_nely} \
    --volfrac ${service_volfrac} \
    --penal ${service_penal} \
    --num-iterations ${service_num_iterations} \
    --load-type ${service_load_type} \
    --results-dir ${RESULTS_DIR} \
    > ${PW_PARENT_JOB_DIR}/topo_opt.log 2>&1 &
sim_pid=$!
echo "kill ${sim_pid} 2>/dev/null" >> ${PW_PARENT_JOB_DIR}/cancel.sh
echo "$(date) Simulation started with PID ${sim_pid}"

# Start dashboard on service_port
echo "$(date) Starting dashboard on port ${service_port}"

python ${SCRIPT_DIR}/dashboard.py \
    --port ${service_port} \
    --results-dir ${RESULTS_DIR} \
    --host 0.0.0.0 \
    > ${PW_PARENT_JOB_DIR}/dashboard.log 2>&1 &
dash_pid=$!
echo "kill ${dash_pid} 2>/dev/null" >> ${PW_PARENT_JOB_DIR}/cancel.sh
echo "$(date) Dashboard started with PID ${dash_pid}"

sleep inf
