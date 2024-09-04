
# Initialize cancel script
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh
docker_port=$(findAvailablePort)
echo "rm /tmp/${docker_port}.port.used" >> cancel.sh


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
     proxy_pass http://127.0.0.1:${docker_port}/me/${openPort}/;
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

echo "Running docker container nginx"
container_name="nginx-${service_port}"
# Remove container when job is canceled
echo "sudo docker stop ${container_name}" >> cancel.sh
echo "sudo docker rm ${container_name}" >> cancel.sh
# Start container
sudo service docker start
touch empty
sudo docker run  -d --name ${container_name} \ 
  -v $PWD/config.conf:/etc/nginx/conf.d/config.conf \
  -v ${PWD}/empty:/etc/nginx/conf.d/default.conf \
  --network=host nginxinc/nginx-unprivileged:1.25.3
# Print logs
sudo docker logs ${container_name}

#########################
# START DOCKER  SERVICE #
#########################
container_name="docker-${service_port}"
echo "sudo docker stop ${container_name}" >> cancel.sh
echo "sudo docker rm ${container_name}" >> cancel.sh

base_url="/me/${openPort}/"

# Docker supports mounting directories that do not exist (singularity does not)
set -x

# Notify platform that service is ready
${sshusercontainer} "${pw_job_dir}/utils/notify.sh Running"

service_docker_cmd=${service_docker_cmd//__docker_port__/$docker_port}
service_docker_cmd=${service_docker_cmd//__base_url__/$base_url}
service_docker_cmd=${service_docker_cmd//__container_name__/$container_name}

echo "Running docker command" 
echo "${service_docker_cmd}"
eval sudo ${service_docker_cmd}

sleep 999999999
