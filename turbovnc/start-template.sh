# Runs via ssh + sbatch
servicePort=__servicePort__
partition_or_controller=__partition_or_controller__
job_number=__job_number__
slurm_module=__slurm_module__
service_bin=__service_bin__
service_background=__service_background__ # Launch service as a background process (! or screen)

# Prepare kill service script
# - Needs to be here because we need the hostname of the compute node.
# - kill-template.sh --> service-kill-${job_number}.sh --> service-kill-${job_number}-main.sh

if [[ ${partition_or_controller} == "True" ]]; then
    # Remove .cluster.local for einteinmed!
    hname=$(hostname | sed "s/.cluster.local//g")
    echo "ssh ${hname} 'bash -s' < ${PWD}/service-kill-${job_number}-main.sh" > service-kill-${job_number}.sh
else
    echo "bash ${PWD}/service-kill-${job_number}-main.sh" > service-kill-${job_number}.sh
fi

cat >> service-kill-${job_number}-main.sh <<HERE
service_pid=\$(cat ${PWD}/service.pid)
if [ -z \${service_pid} ]; then
    echo "ERROR: No service pid was found!"
else
    echo "$(hostname) - Killing process: ${service_pid}"
    pkill -P \${service_pid}
    kill \${service_pid}
fi
HERE

#printf "password\npassword\n\n" | vncpasswd

VNC_DISPLAY=":1"

if [ -z $(which vncserver) ]; then
    vncserver_exec=/opt/TurboVNC/bin/vncserver
    if [ -f "${vncserver_exec}" ]; then
        ${vncserver_exec} -kill $VNC_DISPLAY
        ${vncserver_exec} $VNC_DISPLAY
    else
        echo "ERROR: vncserver command not found!"
        exit 1
    fi
else
    vncserver -kill $VNC_DISPLAY
    vncserver $VNC_DISPLAY
fi

export DISPLAY=$VNC_DISPLAY

job_dir=${PWD}

rm -f ${job_dir}/service.pid
touch ${job_dir}/service.pid

# DESKTOP_CMD="mate-session"
DESKTOP_CMD="startxfce4"

if [ -z $(which $DESKTOP_CMD) ]; then
    echo "WARNING: vnc desktop not found!"
else
    $DESKTOP_CMD &
    echo $! > ${job_dir}/service.pid
fi

# Check if the noVNC directory is present
# - if not copy from user container -> /swift-pw-bin/noVNC-1.3.0.tgz
if ! [ -d "$(echo ~/pworks/noVNC-1.3.0)" ]; then
    echo "Bootstrapping noVNC"
    set -x
    mkdir -p ~/pworks
    ssh_options="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    if [[ ${partition_or_controller} == "True" ]]; then
        # Running in a compute partition
        if [[ "$USERMODE" == "k8s" ]]; then
            # HAVE TO DO THIS FOR K8S NETWORKING TO EXPOSE THE PORT
            # WARNING: Maybe if controller contains user name (user@ip) you need to extract only the ip
            # Works because home directory is shared!
            ssh ${ssh_options} $masterIp scp ${USER_CONTAINER_HOST}:/swift-pw-bin/noVNC-1.3.0.tgz ~/pworks
        else # Docker mode
            # Works because home directory is shared!
            ssh ${ssh_options} $masterIp scp ${USER_CONTAINER_HOST}:/swift-pw-bin/noVNC-1.3.0.tgz ~/pworks
        fi
    else
        # Running in a controller node
        if [[ "$USERMODE" == "k8s" ]]; then
            # HAVE TO DO THIS FOR K8S NETWORKING TO EXPOSE THE PORT
            # WARNING: Maybe if controller contains user name (user@ip) you need to extract only the ip
            scp ${USER_CONTAINER_HOST}:/swift-pw-bin/noVNC-1.3.0.tgz ~/pworks
        else # Docker mode
            scp ${USER_CONTAINER_HOST}:/swift-pw-bin/noVNC-1.3.0.tgz ~/pworks
        fi
    fi
    tar -zxf ~/pworks/noVNC-1.3.0.tgz -C ~/pworks
    set +x
fi
cd  ~/pworks/noVNC-1.3.0

# Load slurm module
# - multiple quotes are used to prevent replacement of __varname__ !!!
if ! [ -z ${slurm_module} ] && ! [[ "${slurm_module}" == "__""slurm_module""__" ]]; then
    echo "module load ${slurm_module}"
    module load ${slurm_module}
fi

if [ -z "$(which screen)" ]; then
    ./utils/novnc_proxy --vnc localhost:5901 --listen localhost:${servicePort} &
    echo $! >> ${job_dir}/service.pid
    sleep 5 # Need this specially in controller node or second software won't show up!

    # Launch service
    if ! [ -z ${service_bin} ] && ! [[ "${service_bin}" == "__""service_bin""__" ]]; then
        export DISPLAY=:1
        if [[ ${service_background} == "False" ]]; then
            echo "Running ${service_bin}"
            ${service_bin}
        else
            echo "Running ${service_bin} in the background"
            ${service_bin} &
            echo $! >> ${job_dir}/service.pid
        fi
    fi

else
    screen -S noVNC-${job_number} -d -m ./utils/novnc_proxy --vnc localhost:5901 --listen localhost:${servicePort}
    pid=$(ps -x | grep noVNC-${job_number} | grep -wv grep | awk '{print $1}')
    echo ${pid} >> ${job_dir}/service.pid
    sleep 5  # Need this specially in controller node or second software won't show up!

    # Launch service:
    if ! [ -z ${service_bin} ] && ! [[ "${service_bin}" == "__""service_bin""__" ]]; then
       
        if [[ ${service_background} == "False" ]]; then
            echo "Running  ${service_bin}"
            ${service_bin}
        else
            echo "Running ${service_bin} in the background"
            screen -S ${service_bin}-${job_number} -d -m ${service_bin}
            pid=$(ps -x | grep ${service_bin}-${job_number} | grep -wv grep | awk '{print $1}')
            echo ${pid} >> ${job_dir}/service.pid
        fi
        echo "Done"
    fi
fi

sleep 99999
