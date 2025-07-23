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
jupyterhub_port=$(findAvailablePort)

if [[ "${service_conda_install}" == "true" ]]; then
    source ${service_conda_sh}
    eval "conda activate ${service_conda_env}"
else
    eval "${service_load_env}"
fi

if [ -z $(which jupyterhub 2> /dev/null) ]; then
    displayErrorMessage "jupyterhub command not found"
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
     proxy_pass http://127.0.0.1:${jupyterhub_port}${basepath}/;
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
# START JUPYTERHUB #
####################
jupyterhub_hubport=$(findAvailablePort)


export JUPYTER_CONFIG_DIR=${PWD}
jupyterhub --generate-config

sed -i "s|^.*c\.Authenticator\.whitelist.*|c.Authenticator.whitelist = set()|" jupyterhub_config.py
sed -i "s|^.*c\.Authenticator\.allow_all.*|c.Authenticator.allow_all = True|" jupyterhub_config.py
sed -i "s|^.*c\.Authenticator\.admin_users.*|c.Authenticator.admin_users = {'${USER}'}|" jupyterhub_config.py
#sed -i "s|^.*c\.Authenticator\.allowed_users.*|c.Authenticator.allowed_users = set()|" jupyterhub_config.py
sed -i "s|^.*c\.JupyterHub\.authenticator_class.*|c.JupyterHub.authenticator_class = 'native'|" jupyterhub_config.py
sed -i "s|^.*c\.JupyterHub\.port.*|c.JupyterHub.port = ${jupyterhub_port}|" jupyterhub_config.py
sed -i "s|^.*c\.JupyterHub\.hub_port.*|c.JupyterHub.hub_port = ${jupyterhub_hubport}|" jupyterhub_config.py
sed -i "s|^.*c\.JupyterHub\.base_url.*|c.JupyterHub.base_url = \'${basepath}/\'|" jupyterhub_config.py
# This link only partially works to embed JupyterHub in an Iframe
# https://discourse.jupyter.org/t/open-jupyterhub-application-in-iframe/10430
#sed -i "s|^.*c\.JupyterHub\.tornado_settings.*|c.JupyterHub.tornado_settings = {\"static_url_prefix\":\"${basepath}/static/\"}|" jupyterhub_config.py


sudo bash -c "source ${service_parent_install_dir}/${service_conda_install_dir}/etc/profile.d/conda.sh; conda activate ${service_conda_env}; jupyterhub -f jupyterhub_config.py"

sleep inf
