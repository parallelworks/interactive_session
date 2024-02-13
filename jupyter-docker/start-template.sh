
# Initialize cancel script
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh
jupyter_port=$(findAvailablePort)
echo "rm /tmp/${jupyter_port}.port.used" >> cancel.sh


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
     proxy_pass http://127.0.0.1:${jupyter_port}/me/${openPort}/;
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
container_name="nginx-${servicePort}"
# Remove container when job is canceled
echo "sudo docker stop ${container_name}" >> cancel.sh
echo "sudo docker rm ${container_name}" >> cancel.sh
# Start container
sudo service docker start
sudo docker run  -d --name ${container_name}  -v $PWD/config.conf:/etc/nginx/conf.d/config.conf --network=host nginxinc/nginx-unprivileged
# Print logs
sudo docker logs ${container_name}

########################
# START JUPYTER DOCKER #
########################
container_name="jupyter-${servicePort}"
echo "sudo docker stop ${container_name}" >> cancel.sh
echo "sudo docker rm ${container_name}" >> cancel.sh

if [[ ${service_use_gpus} == "true" ]]; then
    gpu_flag="--gpus all"
else
    gpu_flag=""
fi

BASE_URL="/me/${openPort}/"

# Docker supports mounting directories that do not exist (singularity does not)
set -x

# Notify platform that service is ready
${sshusercontainer} ${pw_job_dir}/utils/notify.sh

sudo -n docker run ${gpu_flag} -i --rm \
    --name ${container_name} \
    ${service_mount_directories} -v ${HOME}:${HOME} \
    -p ${jupyter_port}:${jupyter_port} \
    ${service_docker_repo} \
    jupyter-notebook \
    --port=${jupyter_port} \
    --ip=0.0.0.0 \
    --no-browser  \
    --allow-root \
    --ServerApp.trust_xheaders=True  \
    --ServerApp.allow_origin='*'  \
    --ServerApp.allow_remote_access=True \
    --ServerApp.token=""  \
    --ServerApp.base_url=${BASE_URL}

sleep 9999