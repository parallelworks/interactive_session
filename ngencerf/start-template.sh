# Initialize cancel script
set -x
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh


# Do nothing if containers are already running
container_id=$(docker ps -q --filter "name=ngencerf-ngencerf-ui")
if ! [ -z "${container_id}" ]; then
  echo "UI containers are already running"
  # Notify platform that service is running
  ${sshusercontainer} "${pw_job_dir}/utils/notify.sh Running"
  sleep infinity
fi

##################################
# Launch SLURM Wrapper Flask App #
##################################
# Transfer Python script
rsync -avzq -e "ssh ${resource_ssh_usercontainer_options_controller}" usercontainer:${pw_job_dir}/${service_name}/slurm-wrapper-app.py slurm-wrapper-app.py
if ! [ -f slurm-wrapper-app.py ]; then
   displayErrorMessage "SLURM wrapper slurm-wrapper-app.py app not found "
fi

# Make sure permissions are set properly
sudo chown -R ${USER} ${LOCAL_DATA_DIR}
sudo chmod -R u+rw ${LOCAL_DATA_DIR}

# Install Flask
sudo pip3.8 install Flask
sudo pip3.8 install gunicorn
# Start Flask app using gunicorn
nohup gunicorn -w ${service_slurm_app_workers} -b 0.0.0.0:5000 slurm-wrapper-app:app > slurm-wrapper-app.log 2>&1 &
slurm_wrapper_pid=$!
echo "kill ${slurm_wrapper_pid}" >> cancel.sh

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

container_name="nginx-${service_port}"
# Remove container when job is canceled
echo "sudo docker stop ${container_name}" >> cancel.sh
echo "sudo docker rm ${container_name}" >> cancel.sh

# Start container
sudo service docker start
touch empty
sudo docker run  -d --name ${container_name} \
    -v $PWD/config.conf:/etc/nginx/conf.d/config.conf \
    -v $PWD/empty:/etc/nginx/conf.d/default.conf \
    --network=host nginxinc/nginx-unprivileged:1.25.3

# Print logs
sudo docker logs ${container_name}


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