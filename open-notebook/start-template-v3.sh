#!/bin/bash
set -ex

# Use a unique project name scoped to this job to avoid collisions when multiple
# sessions run on the same node.
project_name="open_notebook_${PW_JOB_ID:-$$}"

# Initialize cancel script before starting anything so cleanup always works.
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh

# Detect docker command (prefer without sudo, fall back to sudo).
if docker info &>/dev/null; then
    docker_cmd="docker"
elif sudo docker info &>/dev/null; then
    docker_cmd="sudo docker"
else
    echo "$(date) ERROR: Docker is not available on this system" >&2
    exit 1
fi
echo "$(date) Using docker command: ${docker_cmd}"

# Write docker-compose.yml (use > to create/overwrite, never append).
cat > docker-compose.yml <<HERE
services:
  surrealdb:
    image: surrealdb/surrealdb:v2
    command: start --log info --user root --pass root rocksdb:/mydata/mydatabase.db
    user: root
    volumes:
      - ./surreal_data:/mydata
    restart: always

  open_notebook:
    image: lfnovo/open_notebook:v1-latest
    ports:
      - "8502:8502"
    environment:
      # API_URL tells the browser where to reach the API.  The browser calls
      # <API_URL>/api/... which nginx strips of the basepath and forwards to
      # the Next.js frontend (port 8502); Next.js then rewrites /api/* to the
      # FastAPI backend on localhost:5055 internally.  Port 5055 is never
      # exposed outside the container.
      - API_URL=https://${PW_PLATFORM_HOST}${basepath}
      - OPEN_NOTEBOOK_ENCRYPTION_KEY=change-me-to-a-secret-string
      - SURREAL_URL=ws://surrealdb:8000/rpc
      - SURREAL_USER=root
      - SURREAL_PASSWORD=root
      - SURREAL_NAMESPACE=open_notebook
      - SURREAL_DATABASE=open_notebook
    volumes:
      - ./notebook_data:/app/data
    depends_on:
      - surrealdb
    restart: always
HERE

# Register the compose stack in cancel.sh before starting it.
echo "${docker_cmd} compose -p ${project_name} -f ${PWD}/docker-compose.yml down --remove-orphans" >> cancel.sh

${docker_cmd} compose -p "${project_name}" -f "${PWD}/docker-compose.yml" up -d



#######################
# START NGINX WRAPPER #
#######################

proxy_host="127.0.0.1"

# Write config file (use > to create/overwrite, never append).
cat > config.conf <<HERE
server {
 listen ${service_port};
 server_name _;
 index index.html index.htm index.php;
 add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
 add_header 'Access-Control-Allow-Headers' 'Authorization,Content-Type,Accept,Origin,User-Agent,DNT,Cache-Control,X-Mx-ReqToken,Keep-Alive,X-Requested-With,If-Modified-Since';
 add_header X-Frame-Options "ALLOWALL";
 client_max_body_size 1000M;

 # Exact match for the session root without a trailing slash — redirect so
 # the browser always has a trailing slash and the location block below matches.
 location = ${basepath} {
     return 301 ${basepath}/;
 }

 # Primary location: strip the basepath prefix before forwarding to the
 # Next.js frontend.  The trailing slash on proxy_pass is what causes nginx
 # to remove the matched prefix, so Next.js receives a clean path (e.g.
 # /notebooks, /api/...) and can route it correctly.
 location ${basepath}/ {
     proxy_pass http://${proxy_host}:8502/;
     proxy_http_version 1.1;
     proxy_set_header Upgrade \$http_upgrade;
     proxy_set_header Connection "upgrade";
     proxy_set_header X-Real-IP \$remote_addr;
     proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
     proxy_set_header Host \$http_host;
     proxy_set_header X-NginX-Proxy true;
 }

 # Fallback: forward everything else (/_next/static/, /_next/image, etc.)
 # directly to Next.js without any prefix manipulation.  The platform proxy
 # routes these requests to the session node because the browser sends them
 # in the context of the same session.
 location / {
     proxy_pass http://${proxy_host}:8502;
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

cat > nginx.conf <<HERE
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


container_name="nginx-${service_port}"
# Remove container when job is canceled
echo "${docker_cmd} stop ${container_name}" >> cancel.sh
echo "${docker_cmd} rm ${container_name}" >> cancel.sh
# Start container
touch empty
touch nginx.logs
# change ownership to nginx user
sudo chown 101:101 nginx.conf config.conf empty nginx.logs
sudo chmod 644 *.conf
${docker_cmd} run -d --name ${container_name} \
    -v $PWD/config.conf:/etc/nginx/conf.d/config.conf \
    -v $PWD/nginx.conf:/etc/nginx/nginx.conf \
    -v $PWD/empty:/etc/nginx/conf.d/default.conf \
    -v $PWD/nginx.logs:/var/log/nginx/access.log \
    -v $PWD/nginx.logs:/var/log/nginx/error.log \
    --network=host nginxinc/nginx-unprivileged:1.25.3

# Print logs (keeps the job alive; cancel.sh stops the containers on exit)
${docker_cmd} logs ${container_name} -f
