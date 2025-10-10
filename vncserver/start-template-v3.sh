# Make sure no conda environment is activated! 
# https://github.com/parallelworks/issues/issues/1081

start_rootless_docker() {
    local MAX_RETRIES=20
    local RETRY_INTERVAL=2
    local ATTEMPT=1

    export XDG_RUNTIME_DIR=/run/user/$(id -u)
    dockerd-rootless-setuptool.sh install
    PATH=/usr/bin:/sbin:/usr/sbin:$PATH dockerd-rootless.sh --exec-opt native.cgroupdriver=cgroupfs > docker-rootless.log 2>&1 & #--data-root /docker-rootless/docker-rootless/

    # Wait for Docker daemon to be ready
    until docker info > /dev/null 2>&1; do
        if [ $ATTEMPT -le $MAX_RETRIES ]; then
            echo "$(date) Attempt $ATTEMPT of $MAX_RETRIES: Waiting for Docker daemon to start..."
            sleep $RETRY_INTERVAL
            ((ATTEMPT++))
        else
            echo "$(date) ERROR: Docker daemon failed to start after $MAX_RETRIES attempts."
            return 1
        fi
    done

    echo  "$(date): Docker daemon is ready!"
    return 0
}

###################
# PREPARE CLEANUP #
###################

echo '#!/bin/bash' > ${resource_jobdir}/cancel.sh
chmod +x ${resource_jobdir}/cancel.sh
echo "mv ${resource_jobdir}/cancel.sh ${resource_jobdir}/cancel.sh.executed" >> ${resource_jobdir}/cancel.sh
echo "scancel ${SLURM_JOB_ID}"  >> ${resource_jobdir}/cancel.sh

###################
###################

start_gnome_session_with_retries() {
    k=1
    while true; do
        gnome-session
        sleep $((k*60))
        k=$((k+1))
    done
}


if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

if [ -z "${service_nginx_sif}" ]; then
    service_nginx_sif=${service_parent_install_dir}/nginx-unprivileged.sif
fi

service_novnc_tgz_stem=$(echo ${service_novnc_tgz_basename} | sed "s|.tar.gz||g" | sed "s|.tgz||g")
service_novnc_install_dir=${service_parent_install_dir}/${service_novnc_tgz_stem}

# Determine if the service is running in windows using WSL
kernel_version=$(uname -r | tr '[:upper:]' '[:lower:]')

# Deactive default conda environments (required for emed)
export $(env | grep CONDA_PREFIX)
echo ${CONDA_PREFIX}

if ! [ -z "${CONDA_PREFIX}" ]; then
    echo "Deactivating conda environment"
    source ${CONDA_PREFIX}/etc/profile.d/conda.sh
    conda deactivate
fi

set -x

if [[ "${HOSTNAME}" == gaea* && -f /usr/lib/vncserver ]]; then
    export service_vnc_exec=/usr/lib/vncserver
    # vncserver -list does not work
    export service_vnc_type="TigerVNC"
    mkdir -p ${HOME}/.vnc/
    if [ ! -f "${HOME}/.vnc/config" ]; then
    echo "securitytypes=None" > "${HOME}/.vnc/config"
    else
        # Check if the line is already in the file
        if ! grep -Fxq "securitytypes=None" "${HOME}/.vnc/config"; then
            echo "securitytypes=None" >> "${HOME}/.vnc/config"
        fi
    fi
fi

if [ -z "${service_vnc_exec}" ]; then
    service_vnc_exec=$(which vncserver)
fi

if [ -z ${service_vnc_exec} ] || ! [ -f "${service_vnc_exec}" ]; then
    displayErrorMessage "ERROR: vncserver is not installed"
fi

service_vnc_type=$(${service_vnc_exec} -list | grep -oP '(TigerVNC|TurboVNC|KasmVNC)')
if [ -z ${service_vnc_type} ]; then
    displayErrorMessage "ERROR: vncserver type not found. Supported type are TigerVNC, TurboVNC and KasmVNC"
fi

# Find an available display port
minPort=5901
maxPort=5999
for port in $(seq ${minPort} ${maxPort} | shuf); do
    out=$(netstat -aln | grep LISTEN | grep ${port})
    displayNumber=${port: -2}
    XdisplayNumber=$(echo ${displayNumber} | sed 's/^0*//')
    if [ -z "${out}" ] && ! [ -e /tmp/.X11-unix/X${XdisplayNumber} ] && ! [ -e /tmp/.X${XdisplayNumber}-lock ]; then
        # To prevent multiple users from using the same available port --> Write file to reserve it
        portFile=/tmp/${port}.port.used
        if ! [ -f "${portFile}" ]; then
            touch ${portFile}
            echo "rm ${portFile}" >> cancel.sh
            export displayPort=${port}
            export DISPLAY=:${displayNumber#0}
            break
        fi
    fi
done

if [[ "${HOSTNAME}" == gaea* && -f /usr/lib/vncserver ]]; then
cat >> ${resource_jobdir}/cancel.sh <<HERE
service_pid=\$(cat ${resource_jobdir}/service.pid)
if [ -z \"\${service_pid}\" ]; then
    echo "ERROR: No service pid was found!"
else
    echo "$(hostname) - Killing process: \${service_pid}"
    for spid in \${service_pid}; do
        pkill -P \${spid}
    done
    kill \${service_pid}
fi
echo "${resource_jobdir}/vncserver.pid:"
cat ${resource_jobdir}/vncserver.pid
echo "${resource_jobdir}/vncserver.log:"
cat ${resource_jobdir}/vncserver.log
vnc_pid=\$(${resource_jobdir}/vncserver.pid)
pkill -P \${vnc_pid}
kill \${vnc_pid}
HERE

else
cat >> ${resource_jobdir}/cancel.sh <<HERE
service_pid=\$(cat ${resource_jobdir}/service.pid)
if [ -z \${service_pid} ]; then
    echo "ERROR: No service pid was found!"
else
    echo "$(hostname) - Killing process: \${service_pid}"
    for spid in \${service_pid}; do
        pkill -P \${spid}
    done
    kill \${service_pid}
fi
echo "~/.vnc/\${HOSTNAME}${DISPLAY}.pid:"
cat ~/.vnc/\${HOSTNAME}${DISPLAY}.pid
echo "~/.vnc/\${HOSTNAME}${DISPLAY}.log:"
cat ~/.vnc/\${HOSTNAME}${DISPLAY}.log
vnc_pid=\$(cat ~/.vnc/\${HOSTNAME}${DISPLAY}.pid)
pkill -P \${vnc_pid}
kill \${vnc_pid}
rm ~/.vnc/\${HOSTNAME}${DISPLAY}.*
rm /tmp/.X11-unix/X${XdisplayNumber}
HERE
fi


if [[ "${service_vnc_type}" == "TigerVNC" || "${service_vnc_type}" == "TurboVNC" ]]; then
    #########
    # NoVNC #
    #########
    echo; echo "DESKTOP ENVIRONMENT"
    if ! [ -z "${service_desktop}" ]; then
        true
    elif  ! [ -z $(which gnome-session) ]; then
        gsettings set org.gnome.desktop.session idle-delay 0
        service_desktop=gnome-session
    elif ! [ -z $(which mate-session) ]; then
        service_desktop=mate-session
    elif ! [ -z $(which xfce4-session) ]; then
        service_desktop=xfce4-session
    elif ! [ -z $(which icewm-session) ]; then
        # FIXME: Code below fails to launch desktop session
        #        Use case in onyx automatically launches the session when visual apps are launched
        service_desktop=icewm-session
    elif ! [ -z $(which gnome) ]; then
        service_desktop=gnome
    else
        # Exit script here
        displayErrorMessage "ERROR: No desktop environment was found! Tried gnome-session, mate-session, xfce4-session and gnome"
    fi


    # This is only required for turbovnc:
    # https://turbovnc.org/Documentation/Compatibility30
    if [[ ${service_desktop} == "mate-session" ]]; then
        export TVNC_WM=mate
    fi
    
    # Start service
    mkdir -p ~/.vnc
    ${service_vnc_exec} -kill ${DISPLAY}

    # To prevent the process from being killed at startime    
    if [ -f "${HOME}/.vnc/xstartup" ]; then
        sed -i '/vncserver -kill $DISPLAY/ s/^#*/#/' ~/.vnc/xstartup
    else
        echo '#!/bin/sh' > ~/.vnc/xstartup
        echo 'unset SESSION_MANAGER' >> ~/.vnc/xstartup
        echo 'unset DBUS_SESSION_BUS_ADDRESS' >> ~/.vnc/xstartup
        if grep -q 'ID="rocky"' /etc/os-release && grep -q 'VERSION_ID="9\.' /etc/os-release; then
            # Rocky Linux 9. Prevent "Something has gone wrong" message
            echo 'export XDG_SESSION_TYPE=x11' >> ~/.vnc/xstartup
            echo 'export GDK_BACKEND=x11' >> ~/.vnc/xstartup
            echo 'export LIBGL_ALWAYS_SOFTWARE=1' >> ~/.vnc/xstartup
        else
            echo '/etc/X11/xinit/xinitrc' >> ~/.vnc/xstartup
        fi
        chmod +x ~/.vnc/xstartup
    fi

    # service_vnc_type needs to be an input to the workflow in the XML
    # if vncserver is not tigervnc
    if [[ "${HOSTNAME}" == gaea* && -f /usr/lib/vncserver ]]; then
        # FIXME: Change ~/.vnc/config
        ${service_vnc_exec} ${DISPLAY} &> ${resource_jobdir}/vncserver.log &
        echo $! > ${resource_jobdir}/vncserver.pid
    elif [[ ${service_vnc_type} == "TurboVNC" ]]; then
        ${service_vnc_exec} ${DISPLAY} -SecurityTypes None
    else
        # tigervnc
        ${service_vnc_exec} ${DISPLAY} -SecurityTypes=None
    fi

    rm -f ${resource_jobdir}/service.pid
    touch ${resource_jobdir}/service.pid

    # Need this to activate pam_systemd when running under SLURM
    # Otherwise we get permission denied messages when starting the
    # desktop environment
    if [[ ${jobschedulertype} == "SLURM" ]]; then
        ssh -N -f localhost &
        echo $! > ${resource_jobdir}/service.pid
    fi
    
    mkdir -p /run/user/$(id -u)/dconf
    chmod og+rx /run/user/$(id -u)
    chmod 0700 /run/user/$(id -u)/dconf

    # Start desktop here too just in case
    if [[ ${service_desktop} == "gnome-session" ]]; then
        start_gnome_session_with_retries &> start_gnome_session_with_retries.out &
        service_desktop_pid=$!
    else
        eval ${service_desktop} &
        service_desktop_pid=$!
    fi
    echo "${service_desktop_pid}" >> ${resource_jobdir}/service.pid

    cd ${service_novnc_install_dir}
    
    echo "Running ./utils/novnc_proxy --vnc ${HOSTNAME}:${displayPort} --listen ${HOSTNAME}:${service_port}"
    ./utils/novnc_proxy --vnc ${HOSTNAME}:${displayPort} --listen ${HOSTNAME}:${service_port} </dev/null &
    echo $! >> ${resource_jobdir}/service.pid
    pid=$(ps -x | grep vnc | grep ${displayPort} | awk '{print $1}')
    echo ${pid} >> ${resource_jobdir}/service.pid
    rm -f ${portFile}
elif [[ "${service_vnc_type}" == "KasmVNC" ]]; then
    ###########
    # KasmVNC #
    ###########
    export kasmvnc_port=$(findAvailablePort)
    export XDG_RUNTIME_DIR=""

    if [ "${service_set_password}" != true ]; then
        service_password=password
        disableBasicAuth="-disableBasicAuth"
    fi
    #expect -c 'spawn vncpasswd -u '"${USER}"' -w -r; expect "Password:"; send "'"${service_password}"'\r"; expect "Verify:"; send "'"${service_password}"'\r"; expect eof'
    printf "%s\n%s\n" "$service_password" "$service_password" | vncpasswd -u "$USER" -w -r


    ${service_vnc_exec} -kill ${DISPLAY}
    echo "${service_vnc_exec} -kill ${DISPLAY}" >> cancel.sh.sh

    MAX_RETRIES=5
    RETRY_DELAY=5
    RETRY_COUNT=0

    vncserver_cmd="${service_vnc_exec} ${DISPLAY} ${disableBasicAuth} -select-de gnome -websocketPort ${kasmvnc_port} -rfbport ${displayPort}"
    echo Running:
    echo ${vncserver_cmd}
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        ${vncserver_cmd}
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

    if ! [ -f "${HOME}/.vnc/$(hostname)${DISPLAY}.pid" ]; then
        echo $(date): "KasmVNC server failed to start. Exiting workflow."
        exit 1
    fi

    vncserver_pid=$(cat "${HOME}/.vnc/$(hostname)${DISPLAY}.pid")
    echo "kill ${vncserver_pid} #${HOME}/.vnc/$(hostname)${DISPLAY}.pid" >> cancel.sh
    cat "${HOME}/.vnc/$(hostname)${DISPLAY}.log"  >> cancel.sh
    echo "rm \"${HOME}/.vnc/$(hostname)${DISPLAY}*\"" >> cancel.sh
    cat ${HOME}/.vnc/$(hostname)${DISPLAY}.log

    #######################
    # START NGINX WRAPPER #
    #######################

    proxy_port=${kasmvnc_port}
    proxy_host="127.0.0.1"
    if which docker >/dev/null 2>&1 && [[ "${service_rootless_docker}" == "true" ]]; then
        if ! dockerd-rootless-setuptool.sh check; then
            echo "$(date) ERROR: Rootless docker is NOT support on this system"
            exit 1
        fi
        if ! which socat >/dev/null 2>&1; then
            echo "$(date) ERROR: socat is not installed"
            exit 1
        fi
        start_rootless_docker
        # Need to run this for the container to be able to access the port on the host's network
        proxy_port=$(findAvailablePort)
        proxy_host=$(hostname -I | xargs)
        socat TCP-LISTEN:${proxy_port},fork,reuseaddr TCP:127.0.0.1:${kasmvnc_port} >> socat.logs 2>&1 &
        pid=$!
        echo "kill ${pid} #socat" >> cancel.sh
    fi
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
     proxy_pass http://${proxy_host}:${proxy_port};
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

    if which docker >/dev/null 2>&1 && [[ "${service_rootless_docker}" == "true" ]]; then
        container_name="nginx-${service_port}"
        touch empty
        touch nginx.logs
        echo "docker volume rm ${container_name}" >> cancel.sh
        docker volume create ${container_name}
        echo "docker stop ${container_name}" >> cancel.sh
        echo "docker rm ${container_name}" >> cancel.sh
        chmod 644 ${PWD}/{nginx.conf,config.conf,empty}
        docker run  -d --name ${container_name} \
            --add-host=host.docker.internal:host-gateway \
            -p ${service_port}:${service_port} \
            -v $PWD/config.conf:/etc/nginx/conf.d/config.conf \
            -v $PWD/nginx.conf:/etc/nginx/nginx.conf \
            -v $PWD/empty:/etc/nginx/conf.d/default.conf \
            nginxinc/nginx-unprivileged:1.25.3
        # Print logs
        docker logs ${container_name}
    elif sudo -n true 2>/dev/null && which docker >/dev/null 2>&1; then
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
    elif which singularity >/dev/null 2>&1; then
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
        displayErrorMessage "Need Docker or Singularity to start NGINX proxy"
    fi
fi


sleep 6 # Need this specially in controller node or second software won't show up!

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
