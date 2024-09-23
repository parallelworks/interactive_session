# Initialize cancel script
set -x
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh

if [[ "${service_only_connect}" == "true" ]]; then
    echo "Connecting to existing ngencerf service listening on port ${service_existing_port}"
    # Notify platform that service is running
    ${sshusercontainer} "${pw_job_dir}/utils/notify.sh Running"
    sleep infinity
fi


if ! [ -f "${service_nginx_sif}" ]; then
   displayErrorMessage "NGINX proxy singularity container was not found ${service_nginx_sif}"
fi

if ! [ -f "${NGEN_CAL_SINGULARITY_CONTAINER_PATH}" ]; then
   displayErrorMessage "NGEN-CAL singularity container was not found ${NGEN_CAL_SINGULARITY_CONTAINER_PATH}"
fi

#################
# NGINX WRAPPER #
#################

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
     proxy_pass http://127.0.0.1:${service_existing_port}/me/${openPort}/;
     proxy_http_version 1.1;
       proxy_set_header Upgrade \$http_upgrade;
       proxy_set_header Connection "upgrade";
       proxy_set_header X-Real-IP \$remote_addr;
       proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
       proxy_set_header Host \$http_host;
       proxy_set_header X-NginX-Proxy true;
 }

 location /api/ {
     proxy_pass http://127.0.0.1:8000/;
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

echo "Running singularity container ${service_nginx_sif}"
# We need to mount $PWD/tmp:/tmp because otherwise nginx writes the file /tmp/nginx.pid 
# and other users cannot use the node. Was not able to change this in the config.conf.
mkdir -p ./tmp
# Need to overwrite default configuration!
touch empty
singularity run -B $PWD/tmp:/tmp -B $PWD/config.conf:/etc/nginx/conf.d/config.conf -B empty:/etc/nginx/conf.d/default.conf ${service_nginx_sif} &
echo "kill ${pid}" >> cancel.sh


##################################
# Launch SLURM Wrapper Flask App #
##################################
# Transfer Python script
rsync -avzq -e "ssh ${resource_ssh_usercontainer_options_controller}" usercontainer:${pw_job_dir}/${service_name}/slurm-wrapper-app.py slurm-wrapper-app.py
if ! [ -f slurm-wrapper-app.py ]; then
   displayErrorMessage "SLURM wrapper slurm-wrapper-app.py app not found "
fi

# Make sure permissions are set properly
#sudo -n chown -R ${USER} ${LOCAL_DATA_DIR}
sudo -n chmod -R u+rw ${LOCAL_DATA_DIR}

# Install Flask
sudo -n pip3.8 install Flask
sudo -n pip3.8 install gunicorn
sudo -n pip3.8 install requests

# Start Flask app using gunicorn
#gunicorn -w ${service_slurm_app_workers} -b 0.0.0.0:5000 slurm-wrapper-app:app > slurm-wrapper-app.log 2>&1 &
#sudo env LOCAL_DATA_DIR=${LOCAL_DATA_DIR} CONTAINER_DATA_DIR=${CONTAINER_DATA_DIR}  NGEN_CAL_SINGULARITY_CONTAINER_PATH=${NGEN_CAL_SINGULARITY_CONTAINER_PATH} python3.8 slurm-wrapper-app.py > slurm-wrapper-app.log 2>&1 &
#slurm_wrapper_pid=$!
#echo "sudo kill ${slurm_wrapper_pid}" >> cancel.sh
gunicorn -w ${service_slurm_app_workers} -b 0.0.0.0:5000 slurm-wrapper-app:app > slurm-wrapper-app.log 2>&1 &
slurm_wrapper_pid=$!
echo "kill ${slurm_wrapper_pid}" >> cancel.sh



###############
# NGENCERF-UI #
############### 
# service_ngencerf_ui_dir=/ngencerf-app/nextgen_ui/compose.yaml
cat > ${service_ngencerf_ui_dir}/production-pw.yaml <<HERE

name: ngencerf-ui

services:
  ngencerf-app:
    build: 
      context: .
      dockerfile: ./Dockerfile.production-pw
    ports:
      - "${service_existing_port}:3000"
    environment:
      - NUXT_HOST=0.0.0.0
      - NUXT_PORT=3000
      - NUXT_APP_BASE_URL=/me/${openPort}/

HERE

# Notify platform that service is running
${sshusercontainer} "${pw_job_dir}/utils/notify.sh Running"

# Run ngencerf-app
#container_name="ngencerf-ui-ngencerf-app-${service_port}"
#echo "sudo docker stop ${container_name}" >> cancel.sh
cd ${service_ngencerf_docker_dir}

# This command fails
#docker compose run --rm --service-ports --entrypoint bash --name ${container_name}\
#  ngencerf-ui -c "npm run generate && npx --yes serve .output/public/"
# TODO: How about yeah, just run docker compose up from /ngencerf-app/ngencerf-docker/ folder?

#docker compose run --rm --service-ports --entrypoint bash --name ${container_name} ngencerf-ui 

if [[ "${service_build}" == "true" ]]; then
    docker compose -f production-pw.yaml up --build
else
    docker compose -f production-pw.yaml up
fi


sleep infinity
