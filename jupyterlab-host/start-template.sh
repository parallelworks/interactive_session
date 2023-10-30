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
    conda_repo="https://repo.anaconda.com/miniconda/Miniconda3-py39_4.9.2-Linux-x86_64.sh"
    ID=$(date +%s)-${RANDOM} # This script may run at the same time!
    nohup wget ${conda_repo} -O /tmp/miniconda-${ID}.sh 2>&1 > /tmp/miniconda_wget-${ID}.out
    rm -rf ${install_dir}
    mkdir -p $(dirname ${install_dir})
    nohup bash /tmp/miniconda-${ID}.sh -b -p ${install_dir} 2>&1 > /tmp/miniconda_sh-${ID}.out
}



if [[ "${service_conda_install}" == "true" ]]; then
    {
        source ${service_conda_sh}
    } || {
        conda_dir=$(echo ${service_conda_sh} | sed "s|etc/profile.d/conda.sh||g" )
        f_install_miniconda ${conda_dir}
        source ${service_conda_sh}
    }
    {
        conda activate ${service_conda_env}
    } || {
        conda create -n ${service_conda_env} jupyter -y
        conda activate ${service_conda_env}
    }
    if [ -z $(which ${jupyter-notebook} 2> /dev/null) ]; then
        conda install -c conda-forge jupyterlab
        conda install nb_conda_kernels -y
        conda install -c anaconda jinja2 -y
    fi
else
    eval "${service_load_env}"
fi

echo "starting notebook on $servicePort..."

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

container_name="nginx-${servicePort}"
# Remove container when job is canceled
echo "sudo docker stop ${container_name}" >> cancel.sh
echo "sudo docker rm ${container_name}" >> cancel.sh
# Start container
sudo service docker start
sudo docker run  -d --name ${container_name}  -v $PWD/config.conf:/etc/nginx/conf.d/config.conf --network=host nginx
# Print logs
sudo docker logs ${container_name}


####################
# START JUPYTERLAB #
####################
jupyter-lab \
    --port=${jupyterlab_port} \
    --ip=0.0.0.0 \
    --ServerApp.default_url="/me/${openPort}/tree" \
    --ServerApp.iopub_data_rate_limit=10000000000 \
    --ServerApp.token= \
    --ServerApp.password=$sha \
    --no-browser \
    --notebook-dir=${service_notebook_dir} \
    --ServerApp.nbserver_extensions "pw_jupyter_proxy=True" \
    --ServerApp.tornado_settings="{\"static_url_prefix\":\"/me/${openPort}/static/\"}" \
    --ServerApp.allow_origin="*"


sleep 9999
