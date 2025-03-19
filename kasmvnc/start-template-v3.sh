

set -x

if [ -z ${service_novnc_parent_install_dir} ]; then
    service_novnc_parent_install_dir=${HOME}/pw/software
fi

if [ -z "${service_port}" ]; then
    displayErrorMessage "ERROR: No service port found in the range \${minPort}-\${maxPort} -- exiting session"
fi


MAX_RETRIES=5
RETRY_INTERVAL=5
attempt=0
while ! [ -f /etc/pki/tls/private/kasmvnc.pem ] && [ $attempt -lt $MAX_RETRIES ]; do
    kasmvnc_was_installed=true
    echo "Attempt $((attempt+1)) to install kasmvnc..."
    wget ${service_download_url}
    sudo dnf localinstall ./kasmvncserver_*.rpm --allowerasing -y 
    rm ./kasmvncserver_*.rpm
    sleep $RETRY_INTERVAL
    attempt=$((attempt+1))
done

if ! [ -f /etc/pki/tls/private/kasmvnc.pem ]; then
    displayErrorMessage "ERROR: KasmVNC installation failed."
fi

if [ "${kasmvnc_was_installed}" = true ]; then
    sudo usermod -a -G kasmvnc-cert $USER
    newgrp kasmvnc-cert
    #sudo chown $USER /etc/pki/tls/private/kasmvnc.pem
    # Disable ssl
    sudo sed -i 's/require_ssl: true/require_ssl: false/g' /usr/share/kasmvnc/kasmvnc_defaults.yaml
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


# Prepare kill service script
# - Needs to be here because we need the hostname of the compute node.
# - kill-template.sh --> service-kill-${job_number}.sh --> service-kill-${job_number}-main.sh
echo "Creating file ${resource_jobdir}/service-kill-${job_number}-main.sh from directory ${PWD}"
if [[ ${jobschedulertype} == "CONTROLLER" ]]; then
    echo "bash ${resource_jobdir}/service-kill-${job_number}-main.sh" > ${resource_jobdir}/service-kill-${job_number}.sh
else
    # Remove .cluster.local for einteinmed!
    hname=$(hostname | sed "s/.cluster.local//g")
    echo "ssh ${hname} 'bash -s' < ${resource_jobdir}/service-kill-${job_number}-main.sh" > ${resource_jobdir}/service-kill-${job_number}.sh
fi

# YOU NEED TO SET A PASSWORD!
# The password can be ignoted later using vncserver ${DISPLAY} -disableBasicAuth

if [ "${service_set_password}" != true ]; then
    service_password=password
    disableBasicAuth="-disableBasicAuth"
fi
expect -c 'spawn vncpasswd -u '"${USER}"' -w -r; expect "Password:"; send "'"${service_password}"'\r"; expect "Verify:"; send "'"${service_password}"'\r"; expect eof'


vncserver -kill ${DISPLAY}
echo "vncserver -kill ${DISPLAY}" >> ${resource_jobdir}/service-kill-${job_number}-main.sh

MAX_RETRIES=5
RETRY_DELAY=5
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    vncserver ${DISPLAY} ${disableBasicAuth} -select-de gnome -websocketPort ${service_port} -rfbport ${displayPort}
    
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
    displayErrorMessage "KasmVNC server failed to start. Exiting workflow."
fi

vncserver_pid=$(cat "${HOME}/.vnc/${HOSTNAME}${DISPLAY}.pid")
echo "kill ${vncserver_pid}" >> ${resource_jobdir}/service-kill-${job_number}-main.sh
cat "${HOME}/.vnc/${HOSTNAME}${DISPLAY}.log"
echo "rm \"${HOME}/.vnc/${HOSTNAME}${DISPLAY}*\"" >> ${resource_jobdir}/service-kill-${job_number}-main.sh


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
