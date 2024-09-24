# Make sure no conda environment is activated! 
# https://github.com/parallelworks/issues/issues/1081



start_gnome_session_with_retries() {
    while true; do
        gnome-session
        sleep 2
    done
}



if [ -z ${service_novnc_parent_install_dir} ]; then
    service_novnc_parent_install_dir=${HOME}/pw/software
fi

service_novnc_tgz_stem=$(echo ${service_novnc_tgz_basename} | sed "s|.tar.gz||g" | sed "s|.tgz||g")
service_novnc_install_dir=${service_novnc_parent_install_dir}/${service_novnc_tgz_stem}

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

# Runs via ssh + sbatch
vnc_bin=vncserver

if [[ $kernel_version == *microsoft* ]]; then
    service_vnc_exec=NA
fi

# Find an available display port
if [[ $kernel_version == *microsoft* ]]; then
    # In windows only this port works
    displayPort=5900
else
    minPort=5901
    maxPort=5999
    for port in $(seq ${minPort} ${maxPort} | shuf); do
        out=$(netstat -aln | grep LISTEN | grep ${port})
        if [ -z "${out}" ]; then
            # To prevent multiple users from using the same available port --> Write file to reserve it
            portFile=/tmp/${port}.port.used
            if ! [ -f "${portFile}" ]; then
                touch ${portFile}
                export displayPort=${port}
                displayNumber=${displayPort: -2}
                export DISPLAY=:${displayNumber#0}
                break
            fi
        fi
    done
fi

if [ -z "${service_port}" ]; then
    displayErrorMessage "ERROR: No service port found in the range \${minPort}-\${maxPort} -- exiting session"
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

cat >> ${resource_jobdir}/service-kill-${job_number}-main.sh <<HERE
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
HERE
echo


if ! [[ $kernel_version == *microsoft* ]]; then
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
        #displayErrorMessage "ERROR: No desktop environment was found! Tried gnome-session, mate-session, xfce4-session and gnome"
        # The lines below do not run
        echo "WARNING: vnc desktop not found!"
        echo "Attempting to install a desktop environment"
        # Following https://owlhowto.com/how-to-install-xfce-on-centos-7/
        # Install EPEL release
        sudo -n yum install epel-release -y
        # Install Window-x system
        sudo -n yum groupinstall "X Window system" -y
        # Install XFCE
        sudo -n yum groupinstall "Xfce" -y
        if ! [ -z $(which xfce4-session) ]; then
            displayErrorMessage "ERROR: No desktop environment was found! Tried gnome-session, mate-session, xfce4-session and gnome"
        fi
        # Start GUI
        service_desktop=xfce-session
    fi


    # This is only required for turbovnc:
    # https://turbovnc.org/Documentation/Compatibility30
    if [[ ${service_desktop} == "mate-session" ]]; then
        export TVNC_WM=mate
    fi

    if [ -z ${service_vnc_exec} ] || ! [ -f "${service_vnc_exec}" ]; then
        # If no vnc_exec is provided
        if [ -z $(which ${vnc_bin}) ]; then
            # If no vncserver is in PATH:
            echo "Installing tigervnc-server: sudo -n yum install tigervnc-server -y"
            sudo -n yum install tigervnc-server -y
            # python3 is a dependency
            if [ -z $(which python3) ]; then
                sudo -n yum install python3 -y
            fi

        fi
        service_vnc_exec=$(which ${vnc_bin})
    fi
    
    if [ ! -f "${service_vnc_exec}" ]; then
        displayErrorMessage "ERROR: service_vnc_exec=${service_vnc_exec} file not found! - Exiting workflow!"
    fi

    # Start service
    mkdir -p ~/.vnc
    ${service_vnc_exec} -kill ${DISPLAY}

    # To prevent the process from being killed at startime    
    if [ -f "~/.vnc/xstartup" ]; then
        sed -i '/vncserver -kill $DISPLAY/ s/^#*/#/' ~/.vnc/xstartup
    else
        echo '#!/bin/sh' > ~/.vnc/xstartup
        echo 'unset SESSION_MANAGER' >> ~/.vnc/xstartup
        echo 'unset DBUS_SESSION_BUS_ADDRESS' >> ~/.vnc/xstartup
        echo '/etc/X11/xinit/xinitrc' >> ~/.vnc/xstartup
        chmod +x ~/.vnc/xstartup
    fi

    # service_vnc_type needs to be an input to the workflow in the XML
    # if vncserver is not tigervnc
    if [[ ${service_vnc_type} == "turbovnc" ]]; then
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
    chmod 755 /run/user/$(id -u)/dconf

    # Start desktop here too just in case
    if [[ ${service_desktop} == "gnome-session" ]]; then
        start_gnome_session_with_retries &
        service_desktop_pid=$!
    else
        eval ${service_desktop} &
        service_desktop_pid=$!
    fi
    echo "${service_desktop_pid}" >> ${resource_jobdir}/service.pid
fi

cd ${service_novnc_install_dir}

echo "Running ./utils/novnc_proxy --vnc localhost:${displayPort} --listen localhost:${service_port}"
#./utils/novnc_proxy --vnc localhost:${displayPort} --listen localhost:${service_port} </dev/null &>/dev/null &
./utils/novnc_proxy --vnc localhost:${displayPort} --listen localhost:${service_port} </dev/null &
echo $! >> ${resource_jobdir}/service.pid
pid=$(ps -x | grep vnc | grep ${displayPort} | awk '{print $1}')
echo ${pid} >> ${resource_jobdir}/service.pid
rm -f ${portFile}
sleep 6 # Need this specially in controller node or second software won't show up!

# Notify platform that service is running
${sshusercontainer} "${pw_job_dir}/utils/notify.sh Running"

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

sleep 999999999
