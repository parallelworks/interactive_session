set -x
if ! sudo -n true 2>/dev/null; then
    displayErrorMessage "ERROR: CANNOT START DOCKER BECAUSE USER ${USER} DOES NOT HAVE SUDO PRIVILEGES"
fi

# Append the job name to the container's name to make it unique
service_container_name=${job_name}

# Docker container is started with -p ${service_local_port}:${service_container_port}
# - service_local_port is assigned by the workflow from the available ports
# - service_container_port is the server port in the docker container is specified in the inut form
service_local_port=$(findAvailablePort)

#######################
# START NGINX WRAPPER #
#######################

echo "Starting nginx wrapper on service port ${servicePort}"

# Write config file
#cat >> config.conf <<HERE
#server {
# listen ${servicePort};
# server_name _;
# index index.html index.htm index.php;
# add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
# add_header 'Access-Control-Allow-Headers' 'Authorization,Content-Type,Accept,Origin,User-Agent,DNT,Cache-Control,X-Mx-ReqToken,Keep-Alive,X-Requested-With,If-Modified-Since';
# add_header X-Frame-Options "ALLOWALL";
# location / {
#     proxy_pass http://127.0.0.1:${service_local_port}/me/${openPort}/;
#     proxy_http_version 1.1;
#       proxy_set_header Upgrade \$http_upgrade;
#       proxy_set_header Connection "upgrade";
#       proxy_set_header X-Real-IP \$remote_addr;
#       proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
#       proxy_set_header Host \$http_host;
#       proxy_set_header X-NginX-Proxy true;
# }
#}
#HERE

cat >> config.conf <<HERE
http {

  # Support proxying of web-socket connections
  map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
  }
  
  server {
    listen ${servicePort};
    
    location /rstudio/ {
      # Needed only for a custom path prefix of /rstudio
      rewrite ^/rstudio(.*)$ /$1 break;

      # Use http here when ssl-enabled=0 is set in rserver.conf
      proxy_pass http://localhost:${service_local_port};

      proxy_http_version 1.1;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $connection_upgrade;
      proxy_read_timeout 20d;

      # Not needed if www-root-path is set in rserver.conf
      proxy_set_header X-RStudio-Root-Path /me/${openPort};

      # Set the Host header to match how users access your site. Omit :server_port if using the default 80/443
      # so that this value will match the Origin: header for CORS (cross origin security validation)
      proxy_set_header Host $host:$server_port;
    }
  }
}
HERE

nginx_container_name="nginx-${servicePort}"
sudo service docker start
sudo docker run -d --name ${nginx_container_name}  -v $PWD/config.conf:/etc/nginx/conf.d/config.conf --network=host nginx
# Print logs
sudo docker logs ${container_name}



# Remove containers when job is canceled
echo '#/bin/bash/' > docker-kill-${job_number}.sh
if [[ ${jobschedulertype} == "CONTROLLER" ]]; then
    echo sudo -n docker stop ${service_container_name} >> docker-kill-${job_number}.sh
    echo sudo -n docker rm ${service_container_name} >> docker-kill-${job_number}.sh
    echo sudo -n docker stop ${nginx_container_name} >> docker-kill-${job_number}.sh
    echo sudo -n docker rm ${nginx_container_name} >> docker-kill-${job_number}.sh
else
    # Create kill script. Needs to be here because we need the hostname of the compute node.
    echo ssh "'$(hostname)'" sudo -n docker stop ${service_container_name} >> docker-kill-${job_number}.sh
    echo ssh "'$(hostname)'" sudo -n docker rm ${service_container_name} >> docker-kill-${job_number}.sh
    echo ssh "'$(hostname)'" sudo -n docker stop ${nginx_container_name} >> docker-kill-${job_number}.sh
    echo ssh "'$(hostname)'" sudo -n docker rm ${nginx_container_name} >> docker-kill-${job_number}.sh
fi
chmod 777 docker-kill-${job_number}.sh

# Served from 
sudo -n docker run --rm \
    --name ${service_container_name} \
    -p ${service_local_port}:${service_container_port} \
    ${service_docker_options} \
    ${service_docker_repo} ${service_command_line_options}

sleep 9999