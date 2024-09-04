# Runs via ssh + sbatch
set -x

# Initialize cancel script
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh
jupyterlab_port=$(findAvailablePort)
echo "rm /tmp/${jupyterlab_port}.port.used" >> cancel.sh


if [[ "${service_conda_install}" == "true" ]]; then
    source ${service_conda_sh}
    eval "conda activate ${service_conda_env}"
else
    eval "${service_load_env}"
fi

if [ -z $(which jupyter-lab 2> /dev/null) ]; then
    displayErrorMessage "jupyter-lab command not found"
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

echo "Starting nginx wrapper on service port ${service_port}"

# Write config file
cat >> config.conf <<HERE
server {
 listen ${service_port};
 server_name _;
 index index.html index.htm index.php;
 add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
 add_header 'Access-Control-Allow-Headers' 'Authorization,Content-Type,Accept,Origin,User-Agent,DNT,Cache-Control,X-Mx-ReqToken,Keep-Alive,X-Requested-With,If-Modified-Since';
 add_header X-Frame-Options "ALLOWALL";
 client_max_body_size 1000M;
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
    # We need to mount $PWD/tmp:/tmp because otherwise nginx writes the file /tmp/nginx.pid 
    # and other users cannot use the node. Was not able to change this in the config.conf.
    mkdir -p ./tmp
    touch empty
    singularity run -B $PWD/tmp:/tmp -B $PWD/config.conf:/etc/nginx/conf.d/config.conf -B empty:/etc/nginx/conf.d/default.conf ${service_nginx_sif} &
    echo "kill $!" >> cancel.sh
else
    if ! sudo -n true 2>/dev/null; then
        displayErrorMessage "ERROR: NGINX DOCKER CONTAINER CANNOT START PW BECAUSE USER ${USER} DOES NOT HAVE SUDO PRIVILEGES"
    fi

    container_name="nginx-${service_port}"
    # Remove container when job is canceled
    echo "sudo docker stop ${container_name}" >> cancel.sh
    echo "sudo docker rm ${container_name}" >> cancel.sh
    # Start container
    sudo service docker start
    touch empty
    sudo docker run  -d --name ${container_name} \
         -v $PWD/config.conf:/etc/nginx/conf.d/config.conf \
         -v $PWD/empty:/etc/nginx/conf.d/default.conf \
         --network=host nginxinc/nginx-unprivileged:1.25.3
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
${sshusercontainer} "${pw_job_dir}/utils/notify.sh Running"

jupyter-lab --port=${jupyterlab_port} --no-browser --config=${PWD}/jupyter_lab_config.py

sleep 999999999
