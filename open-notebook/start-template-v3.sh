#!/bin/bash

################################################################################
# Interactive Session Service Starter - Open Notebook
#
# Purpose: Start Open Notebook (SurrealDB + Streamlit UI) with nginx proxy
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - service_port: Allocated port (from session_runner)
#   - basepath: URL base path for the session (from workflow inputs.sh)
#   - service_encryption_key: Encryption key for Open Notebook data
#   - service_data_dir: Directory for persistent data (default: job dir/data)
#   - service_version: Docker image tag (default: v1-latest)
################################################################################

if [ -z "${service_parent_install_dir}" ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

if [ -z "${service_data_dir}" ]; then
    service_data_dir=${PW_PARENT_JOB_DIR}/data
fi

if [ -z "${service_version}" ]; then
    service_version="v1-latest"
fi

if [ -z "${service_encryption_key}" ]; then
    echo "$(date) ERROR: service_encryption_key is required" >&2
    exit 1
fi

# Container and network names scoped to this session's port
network_name="open-notebook-net-${service_port}"
surrealdb_name="open-notebook-surrealdb-${service_port}"
open_notebook_name="open-notebook-app-${service_port}"
nginx_name="open-notebook-nginx-${service_port}"

# Detect Docker command (with or without sudo)
if docker info &>/dev/null; then
    docker_cmd="docker"
    echo "$(date) Docker is accessible without sudo"
elif sudo -n docker info &>/dev/null; then
    docker_cmd="sudo docker"
    echo "$(date) Docker requires sudo"
else
    echo "$(date) ERROR: Docker is not available on this system" >&2
    exit 1
fi

# Initialize cancel script (populated after containers start)
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh

# Create persistent data directories
mkdir -p "${service_data_dir}/surreal_data"
mkdir -p "${service_data_dir}/notebook_data"

# Create an isolated Docker network for this session
${docker_cmd} network create "${network_name}"

############################
# PULL DOCKER IMAGES       #
############################
echo "$(date) Pulling Docker images on service node..."
${docker_cmd} pull surrealdb/surrealdb:v2
${docker_cmd} pull "lfnovo/open_notebook:${service_version}"
${docker_cmd} pull nginxinc/nginx-unprivileged:1.25.3

############################
# START SURREALDB          #
############################
echo "$(date) Starting SurrealDB..."
${docker_cmd} run -d \
    --name "${surrealdb_name}" \
    --network "${network_name}" \
    --restart unless-stopped \
    -v "${service_data_dir}/surreal_data:/mydata" \
    surrealdb/surrealdb:v2 \
    start --user root --pass root \
    --bind 0.0.0.0:8000 \
    file:/mydata/database.db

############################
# START OPEN NOTEBOOK APP  #
############################

# Allocate an internal port for the Streamlit UI so nginx can proxy to it
open_notebook_port=$(pw agent open-port)

echo "$(date) Starting Open Notebook (Streamlit UI on internal port ${open_notebook_port})..."
${docker_cmd} run -d \
    --name "${open_notebook_name}" \
    --network "${network_name}" \
    --restart unless-stopped \
    -p "${open_notebook_port}:8502" \
    -v "${service_data_dir}/notebook_data:/app/data" \
    -e OPEN_NOTEBOOK_ENCRYPTION_KEY="${service_encryption_key}" \
    -e SURREAL_URL="ws://${surrealdb_name}:8000/rpc" \
    -e SURREAL_USER=root \
    -e SURREAL_PASSWORD=root \
    -e SURREAL_NAMESPACE=open_notebook \
    -e SURREAL_DATABASE=open_notebook \
    -e STREAMLIT_SERVER_BASE_URL_PATH="${basepath}" \
    "lfnovo/open_notebook:${service_version}"

############################
# START NGINX PROXY        #
############################
echo "$(date) Starting nginx proxy on service port ${service_port}..."

# Write nginx site config
cat > config.conf << HERE
server {
 listen ${service_port};
 server_name _;
 index index.html index.htm index.php;
 add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
 add_header 'Access-Control-Allow-Headers' 'Authorization,Content-Type,Accept,Origin,User-Agent,DNT,Cache-Control,X-Mx-ReqToken,Keep-Alive,X-Requested-With,If-Modified-Since';
 add_header X-Frame-Options "ALLOWALL";
 client_max_body_size 1000M;
 location / {
     proxy_pass http://127.0.0.1:${open_notebook_port}${basepath}/;
     proxy_http_version 1.1;
     proxy_set_header Upgrade \$http_upgrade;
     proxy_set_header Connection "upgrade";
     proxy_set_header X-Real-IP \$remote_addr;
     proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
     proxy_set_header Host \$http_host;
     proxy_set_header X-NginX-Proxy true;
     proxy_read_timeout 86400;
 }
}
HERE

# Write nginx main config (temp paths for unprivileged container)
cat > nginx.conf << HERE
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
    keepalive_timeout  65;

    include /etc/nginx/conf.d/*.conf;
}
HERE

touch empty
touch nginx.logs

if [[ "${docker_cmd}" == "sudo docker" ]]; then
    # With sudo docker: use --network=host so nginx can bind directly to service_port
    sudo chown 101:101 nginx.conf config.conf empty nginx.logs
    sudo chmod 644 nginx.conf config.conf empty
    ${docker_cmd} run -d \
        --name "${nginx_name}" \
        --network=host \
        -v $PWD/config.conf:/etc/nginx/conf.d/config.conf \
        -v $PWD/nginx.conf:/etc/nginx/nginx.conf \
        -v $PWD/empty:/etc/nginx/conf.d/default.conf \
        -v $PWD/nginx.logs:/var/log/nginx/access.log \
        -v $PWD/nginx.logs:/var/log/nginx/error.log \
        nginxinc/nginx-unprivileged:1.25.3
else
    # Rootless docker: map service_port explicitly
    chmod 644 ${PWD}/{nginx.conf,config.conf,empty}
    ${docker_cmd} run -d \
        --name "${nginx_name}" \
        -p "${service_port}:${service_port}" \
        -v $PWD/config.conf:/etc/nginx/conf.d/config.conf \
        -v $PWD/nginx.conf:/etc/nginx/nginx.conf \
        -v $PWD/empty:/etc/nginx/conf.d/default.conf \
        nginxinc/nginx-unprivileged:1.25.3
fi

${docker_cmd} logs "${nginx_name}"

############################
# WRITE CANCEL SCRIPT      #
############################
cat > cancel.sh << CANCEL
#!/bin/bash
${docker_cmd} stop ${nginx_name} 2>/dev/null || true
${docker_cmd} rm   ${nginx_name} 2>/dev/null || true
${docker_cmd} stop ${open_notebook_name} 2>/dev/null || true
${docker_cmd} rm   ${open_notebook_name} 2>/dev/null || true
${docker_cmd} stop ${surrealdb_name} 2>/dev/null || true
${docker_cmd} rm   ${surrealdb_name} 2>/dev/null || true
${docker_cmd} network rm ${network_name} 2>/dev/null || true
CANCEL
chmod +x cancel.sh

echo "$(date) Open Notebook session started."
echo "$(date) Access via platform session URL (basepath: ${basepath})"

# Keep the job alive
sleep inf
