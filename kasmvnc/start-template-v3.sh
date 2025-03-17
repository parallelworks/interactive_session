
if [ -z ${service_novnc_parent_install_dir} ]; then
    service_novnc_parent_install_dir=${HOME}/pw/software
fi

if ! [ -f /etc/pki/tls/private/kasmvnc.pem ]; then
    # FIXME: Only run if kasmvnc is not installed!
    wget https://github.com/kasmtech/KasmVNC/releases/download/v1.3.2/kasmvncserver_oracle_8_1.3.2_x86_64.rpm
    sudo dnf localinstall ./kasmvncserver_*.rpm --allowerasing -y 
    rm ./kasmvncserver_*.rpm
    expect -c 'spawn vncpasswd -u '"${USER}"' -w -r; expect "Password:"; send "password\r"; expect "Verify:"; send "password\r"; expect eof'
    sudo usermod -a -G kasmvnc-cert $USER
    sudo chown $USER /etc/pki/tls/private/kasmvnc.pem
fi


kernel_version=$(uname -r | tr '[:upper:]' '[:lower:]')
# Find an available display port
if [[ $kernel_version != *microsoft* ]]; then
    echo "rm /tmp/${service_port}.port.used" >> ${resource_jobdir}/service-kill-${job_number}.sh
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

expect -c 'spawn vncpasswd -u '"${USER}"' -w -r; expect "Password:"; send "password\r"; expect "Verify:"; send "password\r"; expect eof'
sudo usermod -a -G kasmvnc-cert $USER


vncserver -kill ${DISPLAY}
echo "vncserver -kill ${DISPLAY}" >> ${resource_jobdir}/service-kill-${job_number}-main.sh
vncserver ${DISPLAY} -disableBasicAuth -select-de gnome
rm -rf ${portFile}


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
