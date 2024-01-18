# Runs via ssh + sbatch
set -x

# Start networking to display Dask dashboard in the PW platform
if ! sudo -n true 2>/dev/null; then
    displayErrorMessage "ERROR: NGINX CANNOT START PW BECAUSE USER ${USER} DOES NOT HAVE SUDO PRIVILEGES"
fi


# Initialize cancel script
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh
jupyterlab_port=$(findAvailablePort)
echo "rm /tmp/${jupyterlab_port}.port.used" >> cancel.sh

f_install_miniconda() {
    install_dir=$1
    echo "Installing Miniconda3-py39_4.9.2"
    conda_repo="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
    ID=$(date +%s)-${RANDOM} # This script may run at the same time!
    nohup wget ${conda_repo} -O /tmp/miniconda-${ID}.sh 2>&1 > /tmp/miniconda_wget-${ID}.out
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

    if [[ "${advanced_options_install_instructions}" == "yaml" ]]; then
        printf "%b" "${advanced_options_yaml}" > conda.yaml
        f_set_up_conda_from_yaml ${service_conda_dir} ${service_conda_env} conda.yaml
    elif [[ "${advanced_options_install_instructions}" == "dask" ]]; then
        scp usercontainer:${pw_job_dir}/${service_name}/dask-extension-jupyterlab.yaml conda.yaml
        f_set_up_conda_from_yaml ${service_conda_dir} ${service_conda_env} conda.yaml
    else
    
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
        if [ -z $(which ${jupyter-lab} 2> /dev/null) ]; then
            conda install -c conda-forge jupyterlab -y
            conda install nb_conda_kernels -y
            conda install -c anaconda jinja2 -y
        fi

        # Check if SLURM is installed
        if command -v sinfo &> /dev/null; then
            # SLURM extension for Jupyter Lab https://github.com/NERSC/jupyterlab-slurm
            pip install jupyterlab_slurm
        fi
    fi
else
    eval "${service_load_env}"
fi

export XDG_RUNTIME_DIR=""

# Generate sha:
if [ -z "${service_password}" ]; then
    echo "No password was specified"
    sha=""
else
    echo "Generating sha"
    sha=$(python3 -c "from notebook.auth.security import passwd; print(passwd('${service_password}', algorithm = 'sha1'))")
fi
# Set the launch directory for JupyterHub
# If notebook_dir is not set or set to a templated value,
# use the default value of "/".
if [ -z ${service_notebook_dir} ]; then
    service_notebook_dir="/"
fi

#######################
# START NGINX WRAPPER #
#######################

echo "Starting nginx wrapper on service port ${servicePort}"

# Write config file
cat >> config.conf <<HERE
server {
 listen ${servicePort};
 server_name _;
 index index.html index.htm index.php;
 add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
 add_header 'Access-Control-Allow-Headers' 'Authorization,Content-Type,Accept,Origin,User-Agent,DNT,Cache-Control,X-Mx-ReqToken,Keep-Alive,X-Requested-With,If-Modified-Since';
 add_header X-Frame-Options "ALLOWALL";
 location / {
     proxy_pass http://127.0.0.1:${jupyterlab_port}/me/${openPort}/;
     proxy_http_version 1.1;
       proxy_set_header Upgrade \$http_upgrade;
       proxy_set_header Connection "upgrade";
       proxy_set_header X-Real-IP \$remote_addr;
       proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
       proxy_set_header Host \$http_host;
       proxy_set_header X-NginX-Proxy true;
 }
}
HERE

if [ -f "${service_nginx_sif}" ]; then
    echo "Running singularity container ${service_nginx_sif}"
    singularity run --writable-tmpfs  -B $PWD/config.conf:/etc/nginx/conf.d/config.conf ${service_nginx_sif} &
    echo "kill $!" >> cancel.sh
else
    container_name="nginx-${servicePort}"
    # Remove container when job is canceled
    echo "sudo docker stop ${container_name}" >> cancel.sh
    echo "sudo docker rm ${container_name}" >> cancel.sh
    # Start container
    sudo service docker start
    sudo docker run  -d --name ${container_name}  -v $PWD/config.conf:/etc/nginx/conf.d/config.conf --network=host nginxinc/nginx-unprivileged
    # Print logs
    sudo docker logs ${container_name}
fi

####################
# START JUPYTERLAB #
####################

if [ -z ${service_notebook_dir} ]; then
    service_notebook_dir="/"
fi

export JUPYTER_CONFIG_DIR=${PWD}
jupyter-lab --generate-config

sed -i "s|^.*c\.ExtensionApp\.default_url.*|c.ExtensionApp.default_url = '/me/${openPort}'|" jupyter_lab_config.py
sed -i "s|^.*c\.LabServerApp\.app_url.*|c.LabServerApp.app_url = '/me/${openPort}/lab'|" jupyter_lab_config.py
sed -i "s|^.*c\.LabApp\.app_url.*|c.LabApp.app_url = '/lab'|" jupyter_lab_config.py
sed -i "s|^.*c\.LabApp\.default_url.*|c.LabApp.default_url = '/me/${openPort}/lab'|" jupyter_lab_config.py
sed -i "s|^.*c\.LabApp\.static_url_prefix.*|c.LabApp.static_url_prefix = '/me/${openPort}/static'|" jupyter_lab_config.py
sed -i "s|^.*c\.ServerApp\.allow_origin.*|c.ServerApp.allow_origin = '*'|" jupyter_lab_config.py
sed -i "s|^.*c\.ServerApp\.allow_remote_access.*|c.ServerApp.allow_remote_access = True|" jupyter_lab_config.py
sed -i "s|^.*c\.ServerApp\.base_url.*|c.ServerApp.base_url = '/me/${openPort}'|" jupyter_lab_config.py
sed -i "s|^.*c\.ServerApp\.default_url.*|c.ServerApp.default_url = '/me/${openPort}/'|" jupyter_lab_config.py
sed -i "s|^.*c\.ServerApp\.port.*|c.ServerApp.port = ${jupyterlab_port}|" jupyter_lab_config.py
sed -i "s|^.*c\.ServerApp\.token.*|c.ServerApp.token = ''|" jupyter_lab_config.py
sed -i "s|^.*c\.ServerApp\.tornado_settings.*|c.ServerApp.tornado_settings = {\"static_url_prefix\":\"/me/${openPort}/static/\"}|" jupyter_lab_config.py
sed -i "s|^.*c\.ServerApp\.root_dir.*|c.ServerApp.root_dir = '${service_notebook_dir}'|" jupyter_lab_config.py

# Notify platform that service is running
${sshusercontainer} ${pw_job_dir}/utils/notify.sh

jupyter-lab --port=${jupyterlab_port} --no-browser --config=${PWD}/jupyter_lab_config.py

sleep 9999
