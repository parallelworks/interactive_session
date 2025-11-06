# Initialize cancel script
set -x

echo whoami ": $(whoami)"

PORT=5000
if lsof -i :$PORT >/dev/null 2>&1; then
    echo
    echo "Error: Port $PORT is already in use."
    echo "Please ensure that no other NGENCERF job is currently running in the cluster."
    echo "Exiting workflow run"
    exit 1
fi

# Test if the user can execute a passwordless sudo command
if sudo -n true 2>/dev/null; then
  echo "You can execute passwordless sudo."
else
  echo
  echo "ERROR: You do not have passwordless sudo access. Exiting."
  exit 1
fi

# Get the SLURM version
slurm_version=$(scontrol version | awk '{print $2}' | cut -d'.' -f1)
# Check the SLURM version
if [[ "$slurm_version" == 22* ]]; then
    export SLURM_JOB_METRICS="JobID,Elapsed,NCPUS,CPUTime,MaxRSS,MaxDiskRead,MaxDiskWrite,Reserved"
elif [[ "$slurm_version" == 23* ]]; then
    export SLURM_JOB_METRICS="JobID,Elapsed,NCPUS,CPUTime,MaxRSS,MaxDiskRead,MaxDiskWrite,Planned"
else
    export SLURM_JOB_METRICS="JobID,Elapsed,NCPUS,CPUTime,MaxRSS,MaxDiskRead,MaxDiskWrite,Planned"
fi

ngencerf_port=3000 #$(findAvailablePort)

echo '#!/bin/bash' > cancel.sh
echo "$(date) Running cancel script" >> cancel.sh
chmod +x cancel.sh

if [[ "${service_only_connect}" == "true" ]]; then
    echo "Connecting to existing ngencerf service listening on port ${ngencerf_port}"
    sleep infinity
fi

if ! [ -f "${service_nginx_sif}" ]; then
   displayErrorMessage "NGINX proxy singularity container was not found ${service_nginx_sif}"
fi

if ! [ -f "${nwm_cal_mgr_singularity_container_path}" ]; then
   displayErrorMessage "nwm-cal-mgr singularity container was not found ${nwm_cal_mgr_singularity_container_path}"
fi

if ! [ -f "${ngen_bmi_forcing_singularity_container_path}" ]; then
   displayErrorMessage "ngen-bmi-forcing singularity container was not found ${ngen_bmi_forcing_singularity_container_path}"
fi

if ! [ -f "${nwm_fcst_mgr_singularity_container_path}" ]; then
   displayErrorMessage "nwm-fcst-mgr singularity container was not found ${nwm_fcst_mgr_singularity_container_path}"
fi

if ! [ -f "${nwm_verf_singularity_container_path}" ]; then
   displayErrorMessage "nwm-verf singularity container was not found ${nwm_verf_singularity_container_path}"
fi

#################
# NGINX WRAPPER #
#################

echo "Starting nginx wrapper on service port ${service_port}"

# Write config file
cat >> config.conf <<HERE
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }

server {
  listen ${service_port};
  server_name _;
  index index.html index.htm index.php;
  client_max_body_size 0; # Remove upload size limit by setting to 0

  # timeouts (shorter to notice app hangs)
  proxy_connect_timeout 5s;
  proxy_send_timeout    120s;
  proxy_read_timeout    120s;
  send_timeout          120s;

  # CORS (minimal)
  add_header Access-Control-Allow-Origin  \$http_origin always;
  add_header Vary                         Origin always;
  add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;
  add_header Access-Control-Allow-Headers "Authorization,Content-Type,Accept,Origin,User-Agent,DNT,Cache-Control,X-Mx-ReqToken,Keep-Alive,X-Requested-With,If-Modified-Since" always;

  location / {
    proxy_pass http://127.0.0.1:${ngencerf_port}${basepath}/;
    proxy_http_version 1.1;

    # only upgrade when client asked for it
    proxy_set_header   Upgrade    \$http_upgrade;
    proxy_set_header   Connection \$connection_upgrade;

    proxy_set_header   X-Real-IP         \$remote_addr;
    proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header   X-Forwarded-Proto \$scheme;
    proxy_set_header   X-Forwarded-Host  \$host;
    proxy_set_header   Host              \$host;

    # quick response to CORS preflight
    if (\$request_method = OPTIONS) { return 204; }
  }

  location /api/ {
    proxy_pass http://127.0.0.1:8000/;
    proxy_http_version 1.1;

    proxy_set_header   Upgrade    \$http_upgrade;
    proxy_set_header   Connection \$connection_upgrade;

    proxy_set_header   X-Real-IP         \$remote_addr;
    proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header   X-Forwarded-Proto \$scheme;
    proxy_set_header   X-Forwarded-Host  \$host;
    proxy_set_header   Host              \$host;

    if (\$request_method = OPTIONS) { return 204; }
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

echo "Running singularity container ${service_nginx_sif}"
# We need to mount $PWD/tmp:/tmp because otherwise nginx writes the file /tmp/nginx.pid
# and other users cannot use the node. Was not able to change this in the config.conf.
mkdir -p ./tmp
# Need to overwrite default configuration!
touch empty
singularity run -B $PWD/tmp:/tmp -B $PWD/config.conf:/etc/nginx/conf.d/config.conf -B $PWD/nginx.conf:/etc/nginx/nginx.conf  -B empty:/etc/nginx/conf.d/default.conf ${service_nginx_sif}  >> nginx.logs 2>&1 &
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
# sudo -n chmod -R a+rwX ${local_data_dir}


# SENT="/var/tmp/chmod_since"
# sudo test -f "$SENT" || sudo touch -t 197001010000 "$SENT"

# p="$(command -v nproc >/dev/null 2>&1 && nproc || echo 8)"
# base_dir="${local_data_dir%/}/run-logs"
# [ -d "$base_dir" ] || exit 0

# # sent markers
# sent_epoch="$(sudo stat -c %Y "$SENT")"
# sent_day="$(date -d "@$sent_epoch" +%F)"   # YYYY-MM-DD

# emit_newer_in_dir() {
#   local d="$1"
#   find -L "$d" -xdev \
#     ! -type l \
#     \( -newer "$SENT" -o -cnewer "$SENT" \) -print0
# }

# {
#   # 1) ngen_cal_YYYY-MM-DDThh:mm:ss.xxx directories
#   find "${base_dir%/}" -maxdepth 1 -type d -name 'ngen_cal_*' -print0 |
#   while IFS= read -r -d '' d; do
#     name="$(basename "$d")"                 # ngen_cal_2025-09-02T17:38:54.386
#     ts="${name#ngen_cal_}"                  # 2025-09-02T17:38:54.386
#     ts_nomsec="${ts%%.*}"                   # 2025-09-02T17:38:54
#     dir_day="$(date -d "$ts_nomsec" +%F 2>/dev/null)" || continue
#     [ "$dir_day" \< "$sent_day" ] && continue
#     emit_newer_in_dir "$d"
#   done

#   # 2) YYYY-MM-DD date directories
#   find "${base_dir%/}" -maxdepth 1 -type d -regextype posix-extended \
#        -regex '.*/[0-9]{4}-[0-9]{2}-[0-9]{2}$' -print0 |
#   while IFS= read -r -d '' d; do
#     dir_day="$(basename "$d")"              # e.g., 2025-09-02
#     [ "$dir_day" \< "$sent_day" ] && continue
#     emit_newer_in_dir "$d"
#   done

#   # 3) mswm/YYYYMMDDThhmmss.log files (nested dir)
#   mswm_dir="${base_dir%/}/mswm"
#   if [ -d "$mswm_dir" ]; then
#     find "${mswm_dir%/}" -maxdepth 1 -type f -regextype posix-extended \
#          -regex '.*/[0-9]{8}T[0-9]{6}\.log$' -print0 |
#     while IFS= read -r -d '' f; do
#       fname="$(basename "$f")"              # 20250923T215414.log
#       stamp="${fname%.log}"                 # 20250923T215414
#       iso="${stamp:0:4}-${stamp:4:2}-${stamp:6:2}T${stamp:9:2}:${stamp:11:2}:${stamp:13:2}"
#       file_epoch="$(date -d "$iso" +%s 2>/dev/null || echo '')"
#       [ -n "$file_epoch" ] || continue
#       # same moment or newer than SENT
#       if [ "$file_epoch" -ge "$sent_epoch" ]; then
#         printf '%s\0' "$f"
#       fi
#     done
#   fi

#   # 4) run_calib subtree (mtime/ctime day >= sent_day)
#   find -L "/ngencerf-app/data/ngen-cal-data/ngen-cal-work/run_calib" -xdev \
#     ! -type l \
#     \( -newermt "$sent_day 00:00:00" -o -newerct "$sent_day 00:00:00" \) -print0

# } | sudo xargs -0 -r -P"$p" chmod a+rwX && sudo touch "$SENT"


#mkdir -p ${local_data_dir}/forecast_forcing_work/esmf_mesh
#mkdir -p ${local_data_dir}/forecast_forcing_work/raw_input/HRRR
#mkdir -p ${local_data_dir}/forecast_forcing_work/raw_input/RAP
#sudo chmod -R a+rwX ${local_data_dir}/forecast_forcing_work/
#date > ${local_data_dir}/forecast_forcing_work/date.txt

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
    export MAX_CONFIGURING_WAIT_TIME="840"
    ./update_configuring_jobs.sh > update_configuring_jobs.log 2>&1 &
    echo "kill $!" >> cancel.sh
else
    export PARTITIONS=""
    export MAX_CONFIGURING_WAIT_TIME="9999999999"
fi

# This script is required to run the callback with retries
sed -i "s|__LOCAL_DATA_DIR__|${local_data_dir}|g" run_callback.sh
chmod +x run_callback.sh

/usr/local/bin/gunicorn -w ${service_slurm_app_workers} -b 0.0.0.0:5000 slurm-wrapper-app-v3:app \
  --access-logfile slurm-wrapper-app-v3.log \
  --error-logfile slurm-wrapper-app-v3.log \
  --capture-output \
  --enable-stdio-inheritance > slurm-wrapper-app-v3.log 2>&1 &

#python3.8 slurm-wrapper-app-v3.py > slurm-wrapper-app-v3.log 2>&1 &

slurm_wrapper_pid=$!
echo "kill ${slurm_wrapper_pid}" >> cancel.sh


# Rerun previous callbacks
sed -i "s|__LOCAL_DATA_DIR__|${local_data_dir}|g" run_pending_callbacks.sh
bash run_pending_callbacks.sh >> run_pending_callback.log 2>&1 &
run_pending_callbacks_pid=$!
echo "kill ${run_pending_callbacks_pid} #rerun callbacks" >> cancel.sh

###############
# NGENCERF-UI #
###############
# service_ngencerf_ui_dir=/ngencerf-app/ngencerf-ui/compose.yaml
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

# ensure buildx uses the docker driver (not the docker-container helper)
# TODO: add this to PW start script
if docker buildx ls | grep -qE 'localdocker.+docker.+\*'; then
  : # already selected
elif docker buildx ls | grep -q 'localdocker'; then
  docker buildx use localdocker
else
  docker buildx create --name localdocker --driver docker --use
fi


if [[ "${service_build}" == "true" ]]; then
  # build locally and start ngencerf-server
  CACHE_BUST=$(date +%s) docker compose -f production-pw.yaml up -d --build ngencerf-services

  # build locally and start ngencerf-ui
  docker compose -f production-pw.yaml up -d --build --no-deps ngencerf-ui

else
  # pull ngencerf-server from registry
  CACHE_BUST=$(date +%s) docker compose -f production-pw.yaml pull ngencerf-services

  # start ngencerf-server
  CACHE_BUST=$(date +%s) docker compose -f production-pw.yaml up -d --no-build ngencerf-services

  # build locally and start ngencerf-ui
  # TODO: pull from registry
  docker compose -f production-pw.yaml up -d --build --no-deps ngencerf-ui
fi

ngencerf_image="$(docker compose -f production-pw.yaml config | awk '/ngencerf-server/{flag=1} flag && /image:/{print $2; exit}')"
echo "ngencerf_image=${ngencerf_image}"

# clean any previous temp container quietly
docker rm -f extract >/dev/null 2>&1 || true

# only attempt extract if the image exists locally
if docker image inspect "${ngencerf_image}" >/dev/null 2>&1; then
  docker create --name extract "${ngencerf_image}" >/dev/null
  sudo docker cp extract:/ngencerf/ngencerf-server/cli/dist/ngencerf /usr/local/bin/ngencerf
  docker rm extract >/dev/null
  sudo chmod +x /usr/local/bin/ngencerf
else
  echo "warning: image ${ngencerf_image} not found locally; skipping CLI extract"
fi

# Tail the logs
docker compose -f production-pw.yaml logs -f

sleep infinity
