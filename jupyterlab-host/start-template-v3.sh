# Runs via ssh + sbatch
set -x

start_rootless_docker() {
    local MAX_RETRIES=20
    local RETRY_INTERVAL=2
    local ATTEMPT=1

    export XDG_RUNTIME_DIR=/run/user/$(id -u)
    dockerd-rootless-setuptool.sh install
    PATH=/usr/bin:/sbin:/usr/sbin:$PATH dockerd-rootless.sh --exec-opt native.cgroupdriver=cgroupfs > docker-rootless.log 2>&1 & #--data-root /docker-rootless/docker-rootless/

    # Wait for Docker daemon to be ready
    until docker info > /dev/null 2>&1; do
        if [ $ATTEMPT -le $MAX_RETRIES ]; then
            echo "$(date) Attempt $ATTEMPT of $MAX_RETRIES: Waiting for Docker daemon to start..."
            sleep $RETRY_INTERVAL
            ((ATTEMPT++))
        else
            echo "$(date) ERROR: Docker daemon failed to start after $MAX_RETRIES attempts."
            return 1
        fi
    done

    echo  "$(date): Docker daemon is ready!"
    return 0
}

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

if [ -z "${service_nginx_sif}" ]; then
    service_nginx_sif=${service_parent_install_dir}/nginx-unprivileged.sif
fi

if [ -z "${service_load_env}" ]; then
    service_conda_sh=${service_parent_install_dir}/${service_conda_install_dir}/etc/profile.d/conda.sh
    service_load_env="source ${service_conda_sh}; conda activate ${service_conda_env}"
fi

eval "${service_load_env}"

# Initialize cancel script
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh
jupyterlab_port=$(findAvailablePort)

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
     proxy_pass http://127.0.0.1:${jupyterlab_port}${basepath}/;
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

cat >> nginx.conf <<HERE
worker_processes  2;

error_log  /var/log/nginx/error.log notice;
pid        /tmp/nginx.pid;


events {
    worker_connections  1024;
}


http {
    proxy_temp_path /tmp/proxy_temp;
    client_body_temp_path /tmp/client_temp;
    fastcgi_temp_path /tmp/fastcgi_temp;
    uwsgi_temp_path /tmp/uwsgi_temp;
    scgi_temp_path /tmp/scgi_temp;

    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                      '\$status \$body_bytes_sent "\$http_referer" '
                      '"\$http_user_agent" "\$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile        on;
    #tcp_nopush     on;

    keepalive_timeout  65;

    #gzip  on;

    include /etc/nginx/conf.d/*.conf;
}
HERE

if which docker >/dev/null 2>&1; then
    container_name="nginx-${service_port}"
    touch empty
    touch nginx.logs
    if sudo -n true 2>/dev/null; then
        docker_cmd="sudo docker"
        # Start container
        sudo service docker start
        # change ownership to nginx user
        sudo chown 101:101 nginx.logs  # change ownership to nginx user
    else
        if ! docker ps >/dev/null 2>&1; then
            start_rootless_docker
        fi
        if ! docker ps >/dev/null 2>&1; then
            echo "$(date) ERROR: User cannot run docker"
            exit 1
        fi
        docker_cmd="docker"
        echo "docker volume rm ${container_name}" >> cancel.sh
        docker volume create ${container_name}
    fi
    # Remove container when job is canceled
    echo "${docker_cmd} stop ${container_name}" >> cancel.sh
    echo "${docker_cmd} rm ${container_name}" >> cancel.sh

    ${docker_cmd} run  -d --name ${container_name} \
         -v $PWD/config.conf:/etc/nginx/conf.d/config.conf:ro \
         -v $PWD/nginx.conf:/etc/nginx/nginx.conf:ro \
         -v $PWD/empty:/etc/nginx/conf.d/default.conf:ro \
         --network=host nginxinc/nginx-unprivileged:1.25.3
    # Print logs
    ${docker_cmd} logs ${container_name}
elif which singularity >/dev/null 2>&1; then
    echo "Running singularity container ${service_nginx_sif}"
    # We need to mount $PWD/tmp:/tmp because otherwise nginx writes the file /tmp/nginx.pid 
    # and other users cannot use the node. Was not able to change this in the config.conf.
    mkdir -p ./tmp
    # Need to overwrite default configuration!
    touch empty
    singularity run -B $PWD/tmp:/tmp -B $PWD/config.conf:/etc/nginx/conf.d/config.conf -B $PWD/nginx.conf:/etc/nginx/nginx.conf -B empty:/etc/nginx/conf.d/default.conf ${service_nginx_sif} >> nginx.logs 2>&1 &
    pid=$!
    echo "kill ${pid}" >> cancel.sh
else
    displayErrorMessage "Need Docker or Singularity to start NGINX proxy"
fi


####################
# START JUPYTERLAB #
####################

if [ -z ${service_notebook_dir} ]; then
    service_notebook_dir="/"
fi

export JUPYTER_CONFIG_DIR=${PWD}
rm -f jupyter_lab_config.py
jupyter-lab --generate-config

sed -i "s|^.*c\.ExtensionApp\.default_url.*|c.ExtensionApp.default_url = '${basepath}'|" jupyter_lab_config.py
sed -i "s|^.*c\.LabServerApp\.app_url.*|c.LabServerApp.app_url = '${basepath}/lab'|" jupyter_lab_config.py
sed -i "s|^.*c\.LabApp\.app_url.*|c.LabApp.app_url = '/lab'|" jupyter_lab_config.py
sed -i "s|^.*c\.LabApp\.default_url.*|c.LabApp.default_url = '${basepath}/lab'|" jupyter_lab_config.py
sed -i "s|^.*c\.LabApp\.static_url_prefix.*|c.LabApp.static_url_prefix = '${basepath}/static'|" jupyter_lab_config.py
sed -i "s|^.*c\.ServerApp\.allow_origin.*|c.ServerApp.allow_origin = '*'|" jupyter_lab_config.py
sed -i "s|^.*c\.ServerApp\.allow_remote_access.*|c.ServerApp.allow_remote_access = True|" jupyter_lab_config.py
sed -i "s|^.*c\.ServerApp\.base_url.*|c.ServerApp.base_url = '${basepath}'|" jupyter_lab_config.py
sed -i "s|^.*c\.ServerApp\.default_url.*|c.ServerApp.default_url = '${basepath}/'|" jupyter_lab_config.py
sed -i "s|^.*c\.ServerApp\.port.*|c.ServerApp.port = ${jupyterlab_port}|" jupyter_lab_config.py
sed -i "s|^.*c\.ServerApp\.token.*|c.ServerApp.token = ''|" jupyter_lab_config.py
sed -i "s|^.*c\.ServerApp\.tornado_settings.*|c.ServerApp.tornado_settings = {\"static_url_prefix\":\"${basepath}/static/\"}|" jupyter_lab_config.py
sed -i "s|^.*c\.ServerApp\.root_dir.*|c.ServerApp.root_dir = '${service_notebook_dir}'|" jupyter_lab_config.py

cd ${service_notebook_dir}

# JUICE https://docs.juicelabs.co/docs/juice/intro
if [[ "${juice_use_juice}" == "true" ]]; then
    echo "INFO: Enabling Juice for remote GPU access"
    if [ -z "${juice_exec}" ]; then
        juice_exec=${service_parent_install_dir}/juice/juice
        echo "INFO: Set Juice executable path to ${juice_exec}"
    fi
    
    if ! [ -z "${juice_vram}" ]; then
        vram_arg="--vram ${juice_vram}"
    fi
    if ! [ -z "${juice_pool_ids}" ]; then
        pool_ids_arg="--pool-ids ${juice_pool_ids}"
    fi
    juice_cmd="${juice_exec} run ${juice_cmd_args} ${vram_arg} ${pool_ids_arg}"
    echo "INFO: Prepared Juice command: ${juice_cmd}"
    echo "INFO: Logging into Juice with provided token"
    ${juice_exec} login -t "${JUICE_TOKEN}" || {
        echo "ERROR: Failed to log into Juice"
        exit 1
    }
fi

${juice_cmd} jupyter-lab --port=${jupyterlab_port} --no-browser --config=${PWD}/jupyter_lab_config.py --allow-root
#jupyter-lab --port=${jupyterlab_port} --ip ${HOSTNAME} --no-browser --config=${PWD}/jupyter_lab_config.py

sleep inf
