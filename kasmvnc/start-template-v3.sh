
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

set -x

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

if [ -z "${service_nginx_sif}" ]; then
    service_nginx_sif=${service_parent_install_dir}/nginx-unprivileged.sif
fi

if [ -z "${service_port}" ]; then
    displayErrorMessage "ERROR: No service port found in the range \${minPort}-\${maxPort} -- exiting session"
fi

export service_port=${service_port}



MAX_RETRIES=5
RETRY_INTERVAL=5
attempt=0
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
done

if ! is_kasmvnc_installed; then
    displayErrorMessage "ERROR: KasmVNC installation failed."
fi

# Check if user is already in the group
if ! groups $USER | grep -q "\bkasmvnc-cert\b"; then
    check_sudo_access "Add user to kasmvnc-cert group"
    echo "User is not in kasmvnc-cert group. Adding..."
    sudo usermod -a -G kasmvnc-cert $USER
    echo "Running newgrp to apply group changes..."
    env > env.sh
    newgrp kasmvnc-cert
    source env.sh
else
    echo "User is already in kasmvnc-cert group."
    needs_newgrp=false
fi

if ! groups | grep -q "\bkasmvnc-cert\b"; then
    echo $(date): "ERROR: User is not in kasmvnc-cert group."
    exit 1
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
expect -c 'spawn vncpasswd -u '"${USER}"' -w -r; expect "Password:"; send "'"${service_password}"'\r"; expect "Verify:"; send "'"${service_password}"'\r"; expect eof'


vncserver -kill ${DISPLAY}
echo "vncserver -kill ${DISPLAY}" >> cancel.sh.sh

MAX_RETRIES=5
RETRY_DELAY=5
RETRY_COUNT=0

vncserver_cmd="vncserver ${DISPLAY} ${disableBasicAuth} -select-de gnome -websocketPort ${service_port} -rfbport ${displayPort}"
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
