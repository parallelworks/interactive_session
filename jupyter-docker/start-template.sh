
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
set -x

sudo docker pull ${service_docker_repo}

# Obtain Jupyter version without breaking ssh connection
sudo docker run -i --rm  ${service_docker_repo} jupyter-notebook --version > jupyter.version & 
while [ ! -f "jupyter.version" ]; do
    sleep 2
done
jupyter_major_version=$(cat jupyter.version | cut -d'.' -f1)

container_name="jupyter-${servicePort}"
echo "sudo docker stop ${container_name}" >> cancel.sh
echo "sudo docker rm ${container_name}" >> cancel.sh

if [[ ${service_use_gpus} == "true" ]]; then
    gpu_flag="--gpus all"
else
    gpu_flag=""
fi

if [ -z ${service_notebook_dir} ]; then
    service_notebook_dir="/"
fi

BASE_URL="/me/${openPort}/"

docker_cmd="sudo -n docker run ${gpu_flag} -i --rm --name ${container_name} ${service_mount_directories} -v ${HOME}:${HOME} -p ${jupyter_port}:${jupyter_port}"
jupyter_docker_cmd="${docker_cmd} ${service_docker_repo} jupyter-notebook"

echo "Jupyter Docker Command"
echo "${jupyter_docker_cmd}"
echo "Jupyter version ${jupyter_major_version}"

# Notify platform that service is ready
${sshusercontainer} ${pw_job_dir}/utils/notify.sh

if [ "${jupyter_major_version}" -lt 7 ]; then
    eval ${jupyter_docker_cmd} \
        --port=${servicePort} \
        --ip=0.0.0.0 \
        --NotebookApp.default_url="/me/${openPort}/tree" \
        --NotebookApp.iopub_data_rate_limit=10000000000 \
        --NotebookApp.token= \
        --NotebookApp.password=$sha \
        --no-browser \
        --notebook-dir=${service_notebook_dir} \
        --NotebookApp.tornado_settings="{\"static_url_prefix\":\"/me/${openPort}/static/\"}" \
        --NotebookApp.allow_origin=*
else
    ${jupyter_docker_cmd} \
        --port=${jupyter_port} \
        --ip=0.0.0.0 \
        --no-browser  \
        --allow-root \
        --ServerApp.trust_xheaders=True  \
        --ServerApp.allow_origin='*'  \
        --ServerApp.allow_remote_access=True \
        --ServerApp.token=""  \
        --ServerApp.base_url=${BASE_URL}

fi
sleep 9999