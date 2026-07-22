################################################################################
# Interactive Session Service Starter - Jupyter Notebook Host
#
# Purpose: Serve Jupyter Notebook through a pw endpoint
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - pw_endpoints_args: Arguments for pw endpoints run (--name, --slug, ...)
#   - service_parent_install_dir: Installation directory
#   - service_conda_install: Whether conda was installed by the controller
#   - service_conda_install_dir: Conda installation directory name
#   - service_conda_env: Conda environment name
#   - service_load_env: Command to load jupyter-notebook (when conda_install=false)
#   - service_notebook_dir: Notebook root directory (default: ${HOME})
#   - service_password: Access password (optional)
################################################################################

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

# Always compute the correct conda paths based on install directories
service_conda_sh=${service_parent_install_dir}/${service_conda_install_dir}/etc/profile.d/conda.sh
if [[ "${service_conda_install}" == "true" ]] && [ -z "${service_load_env}" ]; then
    service_load_env="source ${service_conda_sh}; conda activate ${service_conda_env}"
fi

eval "${service_load_env}"

if [ -z $(which jupyter-notebook 2> /dev/null) ]; then
    echo "::error title=Error::jupyter-notebook command not found"
    exit 1
fi

export XDG_RUNTIME_DIR=""

if [ -z ${service_notebook_dir} ]; then
    service_notebook_dir=${HOME}
fi

jupyter_major_version=$(jupyter notebook --version | cut -d'.' -f1)
echo "::notice::Jupyter version:"
jupyter notebook --version

# START SERVICE
# Subdomain endpoints serve the app at the root URL, so the v3 nginx proxy
# (notebook >= 7) and the pw_jupyter_proxy base-path plugin (notebook < 7) are
# not needed. The endpoint requires platform login unless made public.
echo "::group::Start Service"
set -x

if [ "${jupyter_major_version}" -lt 7 ]; then

    if [ -z "${service_password}" ]; then
        echo "::notice::No password was specified"
        sha=""
    else
        echo "::notice::Generating password hash"
        sha=$(python3 -c "from notebook.auth.security import passwd; print(passwd('${service_password}', algorithm = 'sha1'))")
    fi

    # {port} is replaced by pw endpoints run with the local port it forwards to
    pw endpoints run ${pw_endpoints_args} -- jupyter-notebook \
        --port={port} \
        --NotebookApp.iopub_data_rate_limit=10000000000 \
        --NotebookApp.token= \
        --NotebookApp.password=$sha \
        --no-browser \
        --notebook-dir=${service_notebook_dir} \
        --NotebookApp.allow_origin=*

else

    cat > jupyter_notebook_config.py <<EOF
c.ServerApp.root_dir = '${service_notebook_dir}'
c.ServerApp.allow_remote_access = True
c.IdentityProvider.token = ''
EOF

    if ! [ -z "${service_password}" ]; then
        python3 <<'PYEOF' >> jupyter_notebook_config.py
import os
from jupyter_server.auth import passwd
print(f"c.PasswordIdentityProvider.hashed_password = '{passwd(os.environ['service_password'])}'")
PYEOF
    fi

    # {port} is replaced by pw endpoints run with the local port it forwards to
    pw endpoints run ${pw_endpoints_args} -- jupyter-notebook \
        --port {port} \
        --no-browser \
        --config ${PWD}/jupyter_notebook_config.py

fi

if [ $? -ne 0 ]; then
    echo "::error title=Error::pw endpoints command failed"
    # Fail loud: without this, wait_for_endpoint polls forever for an endpoint
    # that will never register
    pw workflows runs cancel ${PW_RUN_SLUG}
    exit 1
fi
echo "::endgroup::"
