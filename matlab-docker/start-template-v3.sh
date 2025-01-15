

# Initialize cancel script
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh
matlab_port=$(findAvailablePort)

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
     proxy_pass http://127.0.0.1:${matlab_port}${basepath}/;
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
    -v $PWD/nginx.conf:/etc/nginx/nginx.conf \
    --network=host nginxinc/nginx-unprivileged:1.25.3
# Print logs
sudo docker logs ${container_name}

#######################
# START MATLAB DOCKER #
#######################
sudo docker pull ${container_name}
container_name="matlab-${service_port}"
echo "sudo docker stop ${container_name}" >> cancel.sh
echo "sudo docker rm ${container_name}" >> cancel.sh

if [[ ${service_use_gpus} == "true" ]]; then
    gpu_flag="--gpus all"
    # FIXME: This should go to the image creation
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo | sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo
    sudo yum-config-manager --enable nvidia-container-toolkit-experimental
    sudo yum install -y nvidia-container-toolkit
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker
else
    gpu_flag=""
fi

MWI_BASE_URL="${basepath}/"

# Docker supports mounting directories that do not exist (singularity does not)
set -x

sudo docker pull  ${service_docker_repo} 

# https://docs.docker.com/config/containers/container-networking/
#    sudo docker run -it --rm -p 8888:8888 --shm-size=512M mathworks/matlab:r2022a -browser
#        cant run "-it" in the workflow! Fails with message: the input device is not a TTY
sudo -n docker run ${gpu_flag} -i --rm \
    --name ${container_name} \
    ${service_mount_directories} -v ${HOME}:${HOME} \
    -p ${matlab_port}:${matlab_port} \
    --shm-size=512M \
    --env MWI_LOG_LEVEL=DEBUG \
    --env MWI_ENABLE_WEB_LOGGING=True \
    --env MWI_APP_HOST=0.0.0.0 \
    --env MWI_APP_PORT=${matlab_port} \
    --env MWI_ENABLE_TOKEN_AUTH=False \
    --env MWI_BASE_URL=${MWI_BASE_URL} \
    ${service_docker_repo} \
    -browser 

#     --env MWI_CUSTOM_HTTP_HEADERS='{"Content-Security-Policy": "frame-ancestors *cloud.parallel.works:* https://cloud.parallel.works:*;"}' \

sleep 999999999
