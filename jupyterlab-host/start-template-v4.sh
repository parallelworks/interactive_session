################################################################################
# Interactive Session Service Starter - JupyterLab Host
#
# Purpose: Serve JupyterLab through a pw endpoint
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - pw_endpoints_args: Arguments for pw endpoints run (--name, --slug, ...)
#   - service_parent_install_dir: Installation directory
#   - service_conda_install: Whether conda was installed by the controller
#   - service_conda_install_dir: Conda installation directory name
#   - service_conda_env: Conda environment name
#   - service_load_env: Command to load jupyter-lab (when conda_install=false)
#   - service_notebook_dir: JupyterLab root directory (default: ${HOME})
#   - service_password: Access password (optional)
################################################################################

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

if [[ "${service_conda_install}" == "true" ]]; then
    service_conda_sh=${service_parent_install_dir}/${service_conda_install_dir}/etc/profile.d/conda.sh
    service_load_env="source ${service_conda_sh}; conda activate ${service_conda_env}"
fi
eval "${service_load_env}"

if [ -z $(which jupyter-lab 2> /dev/null) ]; then
    echo "::error title=Error::jupyter-lab command not found"
    exit 1
fi

if [ -z ${service_notebook_dir} ]; then
    service_notebook_dir=${HOME}
fi

# Subdomain endpoints serve the app at the root URL, so no base_url or reverse
# proxy is needed. The endpoint requires platform login unless made public.
cat > jupyter_lab_config.py <<EOF
c.ServerApp.root_dir = '${service_notebook_dir}'
c.ServerApp.allow_remote_access = True
c.IdentityProvider.token = ''
EOF

if ! [ -z "${service_password}" ]; then
    python3 <<'PYEOF' >> jupyter_lab_config.py
import os
from jupyter_server.auth import passwd
print(f"c.PasswordIdentityProvider.hashed_password = '{passwd(os.environ['service_password'])}'")
PYEOF
fi

# START SERVICE
echo "::group::Start Service"
echo "::notice::Starting JupyterLab: pw endpoints run ${pw_endpoints_args} -- jupyter-lab --port {port}"

set -x
# {port} is replaced by pw endpoints run with the local port it forwards to
pw endpoints run ${pw_endpoints_args} -- jupyter-lab \
    --port {port} \
    --no-browser \
    --allow-root \
    --config ${PWD}/jupyter_lab_config.py

if [ $? -ne 0 ]; then
    echo "::error title=Error::pw endpoints command failed"
    # Fail loud: without this, wait_for_endpoint polls forever for an endpoint
    # that will never register
    pw workflows runs cancel ${PW_RUN_SLUG}
    exit 1
fi
echo "::endgroup::"
