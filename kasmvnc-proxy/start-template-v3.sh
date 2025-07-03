
check_sudo_access() {
    if ! sudo -n true 2>/dev/null; then
        echo "$(date): ERROR: Cannot $1 without root access"
        exit 1
    fi
}

# Check if kasmvnc-server is installed (using rpm -qa and grep)
is_kasmvnc_installed() {
    rpm -qa | grep -q kasmvncserver
}

# Initialize cancel script
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh

# Runs via ssh + sbatch
set -x

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

if [ -z "${service_nginx_sif}" ]; then
    service_nginx_sif=${service_parent_install_dir}/nginx-unprivileged.sif
fi

kasmvnc_port=$(findAvailablePort)
export kasmvnc_port=${kasmvnc_port}

export XDG_RUNTIME_DIR=""

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
     proxy_pass https://127.0.0.1:${kasmvnc_port};
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

if [[ "${resource_type}" == "existing" ]] || [[ "${resource_type}" == "slurmshv2" ]]; then
    echo "Running singularity container ${service_nginx_sif}"
    # We need to mount $PWD/tmp:/tmp because otherwise nginx writes the file /tmp/nginx.pid 
    # and other users cannot use the node. Was not able to change this in the config.conf.
    mkdir -p ./tmp
    # Need to overwrite default configuration!
    touch empty
    singularity run -B $PWD/tmp:/tmp -B $PWD/config.conf:/etc/nginx/conf.d/config.conf -B $PWD/nginx.conf:/etc/nginx/nginx.conf -B empty:/etc/nginx/conf.d/default.conf ${service_nginx_sif} >> nginx.logs 2>&1 &
    pid=$!
    echo "kill ${pid}" >> cancel.sh
else
    container_name="nginx-${service_port}"
    # Remove container when job is canceled
    echo "sudo docker stop ${container_name}" >> cancel.sh
    echo "sudo docker rm ${container_name}" >> cancel.sh
    # Start container
    sudo service docker start
    touch empty
    touch nginx.logs
    # change ownership to nginx user
    sudo chown 101:101 nginx.logs  # change ownership to nginx user
    sudo docker run  -d --name ${container_name} \
         -v $PWD/config.conf:/etc/nginx/conf.d/config.conf \
         -v $PWD/nginx.conf:/etc/nginx/nginx.conf \
         -v $PWD/empty:/etc/nginx/conf.d/default.conf \
         -v $PWD/nginx.logs:/var/log/nginx/access.log \
         -v $PWD/nginx.logs:/var/log/nginx/error.log \
         --network=host nginxinc/nginx-unprivileged:1.25.3
    # Print logs
    sudo docker logs ${container_name}
fi


####################
# START KASMVNC #
####################

MAX_RETRIES=5
RETRY_INTERVAL=5
attempt=0
installed_kasmvnc=false
while ! is_kasmvnc_installed && [ $attempt -lt $MAX_RETRIES ]; do
    check_sudo_access "Install kasmvnc-server"
    echo "Attempt $((attempt+1)) to install kasmvnc..."
    wget ${service_download_url}
    sudo dnf localinstall ./kasmvncserver_*.rpm --allowerasing -y 
    rm ./kasmvncserver_*.rpm
    sleep $RETRY_INTERVAL
    attempt=$((attempt+1))
    # Disable ssl
    #sudo sed -i 's/require_ssl: true/require_ssl: false/g' /usr/share/kasmvnc/kasmvnc_defaults.yaml
    installed_kasmvnc=true
done

if ! is_kasmvnc_installed; then
    displayErrorMessage "ERROR: KasmVNC installation failed."
fi

# Check if user is already in the group
sg kasmvnc-cert -c "groups"
if [[ "${installed_kasmvnc}" == "true" ]]; then
    check_sudo_access "Add user to kasmvnc-cert group"
    echo "User is not in kasmvnc-cert group. Adding..."
    sudo usermod -a -G kasmvnc-cert $USER
    sg kasmvnc-cert -c "groups"
else
    echo "User is already in kasmvnc-cert group."
fi

kernel_version=$(uname -r | tr '[:upper:]' '[:lower:]')
# Find an available display port
if [[ $kernel_version == *microsoft* ]]; then
    # In windows only this port works
    displayPort=5900
else
    minPort=5901
    maxPort=5999
    for port in $(seq ${minPort} ${maxPort} | shuf); do
        out=$(netstat -aln | grep LISTEN | grep ${port})
        displayNumber=${port: -2}
        XdisplayNumber=$(echo ${displayNumber} | sed 's/^0*//')
        if [ -z "${out}" ] && ! [ -e /tmp/.X11-unix/X${XdisplayNumber} ]; then
            # To prevent multiple users from using the same available port --> Write file to reserve it
            portFile=/tmp/${port}.port.used
            if ! [ -f "${portFile}" ]; then
                touch ${portFile}
                export displayPort=${port}
                export DISPLAY=:${displayNumber#0}
                break
            fi
        fi
    done
fi


# YOU NEED TO SET A PASSWORD!
# The password can be ignoted later using vncserver ${DISPLAY} -disableBasicAuth

if [ "${service_set_password}" != true ]; then
    service_password=password
    disableBasicAuth="-disableBasicAuth"
fi
sg kasmvnc-cert -c "expect -c 'spawn vncpasswd -u ${USER} -w -r; expect \"Password:\"; send \"${service_password}\r\"; expect \"Verify:\"; send \"${service_password}\r\"; expect eof'"

vncserver -kill ${DISPLAY}
echo "vncserver -kill ${DISPLAY}" >> cancel.sh.sh

MAX_RETRIES=5
RETRY_DELAY=5
RETRY_COUNT=0

vncserver_cmd="sg kasmvnc-cert -c \"vncserver ${DISPLAY} ${disableBasicAuth} -select-de gnome -websocketPort ${kasmvnc_port} -rfbport ${displayPort}\""
echo Running:
echo ${vncserver_cmd}
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    eval ${vncserver_cmd}
    if [ $? -eq 0 ]; then
        echo "KasmVNC server started successfully."
        break
    else
        echo "KasmVNC server failed to start. Retrying in $RETRY_DELAY seconds..."
        ls -l /etc/pki/tls/private/kasmvnc.pem
        sleep $RETRY_DELAY
    fi
    
    RETRY_COUNT=$((RETRY_COUNT + 1))
done

rm -rf ${portFile}

if ! [ -f "${HOME}/.vnc/${HOSTNAME}${DISPLAY}.pid" ]; then
    echo $(date): "KasmVNC server failed to start. Exiting workflow."
    exit 1
fi

vncserver_pid=$(cat "${HOME}/.vnc/${HOSTNAME}${DISPLAY}.pid")
echo "kill ${vncserver_pid}" >> cancel.sh
cat "${HOME}/.vnc/${HOSTNAME}${DISPLAY}.log"
echo "rm \"${HOME}/.vnc/${HOSTNAME}${DISPLAY}*\"" >> cancel.sh


# Reload env in case it was deactivated in the step above (e.g.: conda activate)
eval "${service_load_env}"

# Launch service
cd
if ! [ -z "${service_bin}" ]; then
    if [[ ${service_background} == "False" ]]; then
        echo "Running ${service_bin}"
        eval ${service_bin}
    else
        echo "Running ${service_bin} in the background"
        eval ${service_bin} &
        echo $! >> ${resource_jobdir}/service.pid
    fi
fi

sleep inf
