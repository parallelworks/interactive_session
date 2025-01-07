# Initialize cancel script
set -x


# Test if the user can execute a passwordless sudo command
if sudo -n true 2>/dev/null; then
  echo "You can execute passwordless sudo."
else
  echo
  echo "ERROR: You do not have passwordless sudo access. Exiting."
  exit 1
fi

ngencerf_port=3000 #$(findAvailablePort)

echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh

if [[ "${service_only_connect}" == "true" ]]; then
    echo "Connecting to existing ngencerf service listening on port ${ngencerf_port}"
    sleep infinity
fi


if ! [ -f "${service_nginx_sif}" ]; then
   displayErrorMessage "NGINX proxy singularity container was not found ${service_nginx_sif}"
fi

if ! [ -f "${ngen_cal_singularity_container_path}" ]; then
   displayErrorMessage "NGEN-CAL singularity container was not found ${ngen_cal_singularity_container_path}"
fi

# FIXME: Uncomment
#if ! [ -f "${ngen_forcing_singularity_container_path}" ]; then
#   displayErrorMessage "NGEN-FORCING singularity container was not found ${ngen_forcing_singularity_container_path}"
#fi

#if ! [ -f "${ngen_fcst_singularity_container_path}" ]; then
#   displayErrorMessage "NGEN-FCST singularity container was not found ${ngen_fcst_singularity_container_path}"
#fi


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
 client_max_body_size 0;  # Remove upload size limit by setting to 0
 location / {
     proxy_pass http://127.0.0.1:${ngencerf_port}${basepath}/;
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
singularity run -B $PWD/tmp:/tmp -B $PWD/config.conf:/etc/nginx/conf.d/config.conf -B empty:/etc/nginx/conf.d/default.conf ${service_nginx_sif}  >> nginx.logs 2>&1 &
echo "kill $!" >> cancel.sh


##################################
# Launch SLURM Wrapper Flask App #
##################################
# Transfer Python script
if ! [ -f slurm-wrapper-app-v3.py ]; then
   displayErrorMessage "SLURM wrapper slurm-wrapper-app-v3.py app not found "
fi

# Make sure permissions are set properly
#sudo -n chown -R ${USER} ${local_data_dir}
sudo -n chmod -R u+rw ${local_data_dir}

# Install Flask
sudo -n pip3.8 install Flask
sudo -n pip3.8 install gunicorn

# Start Flask app using gunicorn
#gunicorn -w ${service_slurm_app_workers} -b 0.0.0.0:5000 slurm-wrapper-app:app > slurm-wrapper-app-v3.log 2>&1 &
#sudo env local_data_dir=${local_data_dir} CONTAINER_DATA_DIR=${CONTAINER_DATA_DIR}  ngen_cal_singularity_container_path=${ngen_cal_singularity_container_path} python3.8 slurm-wrapper-app-v3.py > slurm-wrapper-app-v3.log 2>&1 &
#slurm_wrapper_pid=$!
#echo "sudo kill ${slurm_wrapper_pid}" >> cancel.sh

export PARTITIONS=$(scontrol show partition | awk -F '=' '/^PartitionName=/ {printf "%s,", $2}' | sed 's/,$//')
PARTITION_COUNT=$(echo "${PARTITIONS}" | tr ',' '\n' | wc -l)

# Write config file
cat >> update_configuring_jobs.sh <<HERE
#!/bin/bash
while true; do
    sleep 60
    curl -s -X POST http://0.0.0.0:5000/update-configuring-jobs
done
HERE
chmod +x update_configuring_jobs.sh


if [ "${PARTITION_COUNT}" -gt 1 ]; then
    echo "ACTIVATING JOB RESUBMISSION"
    export MAX_CONFIGURING_WAIT_TIME="600"
    ./update_configuring_jobs.sh > update_configuring_jobs.log 2>&1 &
    echo "kill $!" >> cancel.sh
else
    export PARTITIONS=""
    export MAX_CONFIGURING_WAIT_TIME="9999999999"
fi


/usr/local/bin/gunicorn -w ${service_slurm_app_workers} -b 0.0.0.0:5000 slurm-wrapper-app-v3:app \
  --access-logfile slurm-wrapper-app-v3.log \
  --error-logfile slurm-wrapper-app-v3.log \
  --capture-output \
  --enable-stdio-inheritance > slurm-wrapper-app-v3.log 2>&1 &
  
#python3.8 slurm-wrapper-app-v3.py > slurm-wrapper-app-v3.log 2>&1 &

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
      args:
        NGENCERF_BASE_URL: https://${pw_platform_host}${basepath}/api/
    ports:
      - "${ngencerf_port}:3000"
    environment:
      - NUXT_HOST=0.0.0.0
      - NUXT_PORT=3000
      - NUXT_APP_BASE_URL=${basepath}/

HERE

# Grant write permissions to all users
chmod a+w ${service_ngencerf_ui_dir}/production-pw.yaml

#sed -i "s|^ENV NGENCERF_BASE_URL=.*|ENV NGENCERF_BASE_URL=\"https://${pw_platform_host}${basepath}/api/\"|" ${service_ngencerf_ui_dir}/Dockerfile.production-pw


# Run ngencerf-app
#container_name="ngencerf-ui-ngencerf-app-${service_port}"
#echo "sudo docker stop ${container_name}" >> cancel.sh
echo "cd ${service_ngencerf_docker_dir}" >> cancel.sh
echo "docker compose -f production-pw.yaml down --remove-orphans" >> cancel.sh

cd ${service_ngencerf_docker_dir}

# This command fails
#docker compose run --rm --service-ports --entrypoint bash --name ${container_name}\
#  ngencerf-ui -c "npm run generate && npx --yes serve .output/public/"
# TODO: How about yeah, just run docker compose up from /ngencerf-app/ngencerf-docker/ folder?

#docker compose run --rm --service-ports --entrypoint bash --name ${container_name} ngencerf-ui 

if [[ "${service_build}" == "true" ]]; then
    docker compose -f production-pw.yaml up --build -d
else
    docker compose -f production-pw.yaml up -d
fi

# Tail the logs
docker compose -f production-pw.yaml logs -f

sleep infinity
