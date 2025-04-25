# Runs via ssh + sbatch
set -x

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

if [[ "${resource_type}" == "existing" ]] || [[ "${resource_type}" == "slurmshv2" ]]; then
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
    container_name="nginx-${service_port}"
    # Remove container when job is canceled
    echo "sudo docker stop ${container_name}" >> cancel.sh
    echo "sudo docker rm ${container_name}" >> cancel.sh
    # Start container
    sudo service docker start
    touch empty
    touch nginx.logs
    # change ownership to nginx user
    sudo chown 101:101 nginx.logs  # change ownership to nginx user
    sudo docker run  -d --name ${container_name} \
         -v $PWD/config.conf:/etc/nginx/conf.d/config.conf \
         -v $PWD/nginx.conf:/etc/nginx/nginx.conf \
         -v $PWD/empty:/etc/nginx/conf.d/default.conf \
         -v $PWD/nginx.logs:/var/log/nginx/access.log \
         -v $PWD/nginx.logs:/var/log/nginx/error.log \
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
jupyter-lab --generate-config --y

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

jupyter-lab --port=${jupyterlab_port} --no-browser --config=${PWD}/jupyter_lab_config.py
#jupyter-lab --port=${jupyterlab_port} --ip ${HOSTNAME} --no-browser --config=${PWD}/jupyter_lab_config.py

sleep inf
