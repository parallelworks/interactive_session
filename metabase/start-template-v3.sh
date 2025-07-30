# This script runs in an environment with the following variables:

# Defined in the input form:
# - jobschedulertype
# - service_mount_directories
# - service_docker_repo

# Added by the workflow
# - job_number: PW job number, e.g.: 00001


# service_port: This value can be specified in the input form. Otherwise, the workflow 
#              selects any available port

# Check if the user can execute commands with sudo
if ! sudo -v >/dev/null 2>&1; then
    displayErrorMessage "You do not have sudo access. Exiting."
fi

set -x

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
     proxy_pass https://127.0.0.1:3000/;
     proxy_http_version 1.1;
       proxy_set_header Upgrade \$http_upgrade;
       proxy_set_header Connection "upgrade";
       proxy_set_header X-Real-IP \$remote_addr;
       proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
       proxy_set_header Host \$http_host;
       proxy_set_header X-NginX-Proxy true;
       proxy_hide_header Content-Security-Policy;
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

# Run docker container
container_name="metabase-${service_port}"

# CREATE CANCEL SCRIPT TO REMOVE DOCKER CONTAINER WHEN THE PW JOB IS CANCELED
if [[ ${jobschedulertype} == "CONTROLLER" ]]; then
    echo sudo "sudo docker stop ${container_name}" > docker-kill-${job_number}.sh
    echo sudo "sudo docker rm ${container_name}" >> docker-kill-${job_number}.sh
else
    # Create kill script. Needs to be here because we need the hostname of the compute node.
    echo ssh "'$(hostname)' sudo docker stop ${container_name}" > docker-kill-${job_number}.sh
    echo ssh "'$(hostname)' sudo docker rm ${container_name}" >> docker-kill-${job_number}.sh
fi

chmod 777 docker-kill-${job_number}.sh

# Start container
sudo systemctl start docker
sudo -n docker run -d -p 3000:3000 \
  -v ~/metabase-data:/metabase-data \
  -e "MB_DB_FILE=/metabase-data/metabase.db" \
  --name ${container_name} ${service_image}

sudo docker logs ${container_name}

# If running docker with the -d option sleep here! 
# Do not exit this script until the job is canceled!
# Exiting this script before the job is canceled triggers the cancel script!
sleep inf
