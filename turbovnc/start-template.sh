# Runs via ssh + sbatch
partition_or_controller=__partition_or_controller__
job_number=__job_number__
slurm_module=__slurm_module__
service_bin="$(echo __service_bin__  | sed "s|---| |g")"
service_background=__service_background__ # Launch service as a background process (! or screen)
chdir=__chdir__
vnc_exec=__vnc_exec__
novnc_dir=__novnc_dir__
novnc_tgz=__novnc_tgz__
vnc_bin=vncserver

bootstrap_tgz() {
    tgz_path=$1
    install_dir=$2
    # Check if the code directory is present
    # - if not copy from user container -> /swift-pw-bin/noVNC-1.3.0.tgz
    if ! [ -d "${install_dir}" ]; then
        echo "Bootstrapping ${install_dir}"
        install_parent_dir=$(dirname ${install_dir})
        mkdir -p ${install_parent_dir}
        
        # first check if the noVNC file is available on the node
        if [[ -f "/core/pworks-main/${tgz_path}" ]]; then
            cp /core/pworks-main/${tgz_path} ${install_parent_dir}
        else
            ssh_options="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
            if [[ ${partition_or_controller} == "True" ]]; then
                # Running in a compute partition
                if [[ "$USERMODE" == "k8s" ]]; then
                    # HAVE TO DO THIS FOR K8S NETWORKING TO EXPOSE THE PORT
                    # WARNING: Maybe if controller contains user name (user@ip) you need to extract only the ip
                    # Works because home directory is shared!
                    ssh ${ssh_options} $masterIp scp ${USER_CONTAINER_HOST}:${tgz_path} ${install_parent_dir}
                else # Docker mode
                    # Works because home directory is shared!
                    ssh ${ssh_options} $masterIp scp ${USER_CONTAINER_HOST}:${tgz_path} ${install_parent_dir}
                fi
            else
                # Running in a controller node
                if [[ "$USERMODE" == "k8s" ]]; then
                    # HAVE TO DO THIS FOR K8S NETWORKING TO EXPOSE THE PORT
                    # WARNING: Maybe if controller contains user name (user@ip) you need to extract only the ip
                    scp ${USER_CONTAINER_HOST}:${tgz_path} ${install_parent_dir}
                else # Docker mode
                    scp ${USER_CONTAINER_HOST}:${tgz_path} ${install_parent_dir}
                fi
            fi
        fi
        tar -zxf ${install_parent_dir}/$(basename ${tgz_path}) -C ${install_parent_dir}
    fi
}

if [ -z ${novnc_dir} ] || [[ "${novnc_dir}" == "__""novnc_dir""__" ]]; then
    novnc_dir=${HOME}/pworks/noVNC-1.3.0
fi

if [ -z ${novnc_tgz} ] || [[ "${novnc_tgz}" == "__""novnc_tgz""__" ]]; then
    novnc_tgz=/swift-pw-bin/apps/noVNC-1.3.0.tgz
fi

# Find an available display port
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

if [ -z "${servicePort}" ]; then
    echo "ERROR: No service port found in the range \${minPort}-\${maxPort} -- exiting session"
    exit 1
fi

# Prepare kill service script
# - Needs to be here because we need the hostname of the compute node.
# - kill-template.sh --> service-kill-${job_number}.sh --> service-kill-${job_number}-main.sh
echo "Creating file ${chdir}/service-kill-${job_number}-main.sh from directory ${PWD}"
if [[ ${partition_or_controller} == "True" ]]; then
    # Remove .cluster.local for einteinmed!
    hname=$(hostname | sed "s/.cluster.local//g")
    echo "ssh ${hname} 'bash -s' < ${chdir}/service-kill-${job_number}-main.sh" > ${chdir}/service-kill-${job_number}.sh
else
    echo "bash ${chdir}/service-kill-${job_number}-main.sh" > ${chdir}/service-kill-${job_number}.sh
fi

cat >> ${chdir}/service-kill-${job_number}-main.sh <<HERE
service_pid=\$(cat ${chdir}/service.pid)
if [ -z \${service_pid} ]; then
    echo "ERROR: No service pid was found!"
else
    echo "$(hostname) - Killing process: ${service_pid}"
    pkill -P \${service_pid}
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

# FIND SERVER EXECUTABLE (BOOTSTRAP)
if [ -z ${vnc_exec} ] || [[ "${vnc_exec}" == "__""vnc_exec""__" ]]; then
    # If no vnc_exec is provided
    if [ -z $(which ${vnc_bin}) ]; then
        # If no vncserver is in PATH:
        echo "Installing tigervnc-server: sudo yum install tigervnc-server -y"
        sudo yum install tigervnc-server -y
        # python3 is a dependency
        if [ -z $(which python3) ]; then
            sudo yum install python3 -y
        fi

    fi
    vnc_exec=$(which ${vnc_bin})
fi

if [ ! -f "${vnc_exec}" ]; then
    echo ERROR: vnc_exec=${vnc_exec} file not found! - Existing workflow!
    exit 1
fi

# Start service
${vnc_exec} -kill ${DISPLAY}
# FIXME: Need better way of doing this:
# Turbovnc fails with "=" and tigevnc fails with " "
{
    ${vnc_exec} ${DISPLAY} -SecurityTypes None
} || {
    ${vnc_exec} ${DISPLAY} -SecurityTypes=None
}

rm -f ${chdir}/service.pid
touch ${chdir}/service.pid


if ! [ -z $(which mate-session) ]; then
    mate-session &
    echo $! > ${chdir}/service.pid
elif  ! [ -z $(which gnome-session) ]; then
    gnome-session &
    echo $! > ${chdir}/service.pid
elif ! [ -z $(which gnome) ]; then
    gnome &
    echo $! > ${chdir}/service.pid
else
    if [ -z  $(ps -x | grep xfce4-panel | grep -wv grep) ]; then
        echo "WARNING: vnc desktop not found!"
        echo "Attempting to install a desktop environment"
        # Following https://owlhowto.com/how-to-install-xfce-on-centos-7/
        # Install EPEL release
        sudo yum install epel-release -y
        # Install Window-x system
        sudo yum groupinstall "X Window system" -y
        # Install XFCE
        sudo yum groupinstall "Xfce" -y
        # Starting the GUI
        sudo systemctl isolate graphical.target
        # Enable GUI on boot
        sudo systemctl set-default graphical.target
        # Start GUI
        xfce4-panel -r && xfwm4 --replace &
        echo $! > ${chdir}/service.pid
    fi
fi

bootstrap_tgz ${novnc_tgz} ${novnc_dir}
cd ${novnc_dir}

echo
# Load slurm module
# - multiple quotes are used to prevent replacement of __varname__ !!!
if ! [ -z ${slurm_module} ] && ! [[ "${slurm_module}" == "__""slurm_module""__" ]]; then
    echo "module load ${slurm_module}"
    module avail ${slurm_module}
    module load ${slurm_module}
fi
echo

if [ -z "$(which screen)" ]; then
    ./utils/novnc_proxy --vnc localhost:${displayPort} --listen localhost:${servicePort} &
    echo $! >> ${chdir}/service.pid
    pid=$(ps -x | grep vnc | grep ${displayPort} | awk '{print $1}')
    echo ${pid} >> ${chdir}/service.pid
    rm -f ${portFile}
    sleep 5 # Need this specially in controller node or second software won't show up!
    
    # Launch service
    if ! [ -z "${service_bin}" ] && ! [[ "${service_bin}" == "__""service_bin""__" ]]; then
        if [[ ${service_background} == "False" ]]; then
            echo "Running ${service_bin}"
            ${service_bin}
        else
            echo "Running ${service_bin} in the background"
            ${service_bin} &
            echo $! >> ${chdir}/service.pid
        fi
    fi
    
else
    screen -S noVNC-${job_number} -d -m ./utils/novnc_proxy --vnc localhost:${displayPort} --listen localhost:${servicePort}
    rm -f ${portFile}
    pid=$(ps -x | grep noVNC-${job_number} | grep -wv grep | awk '{print $1}')
    echo ${pid} >> ${chdir}/service.pid
    pid=$(ps -x | grep vnc | grep ${displayPort} | awk '{print $1}')
    echo ${pid} >> ${chdir}/service.pid
    sleep 5  # Need this specially in controller node or second software won't show up!
    
    # Launch service:
    if ! [ -z "${service_bin}" ] && ! [[ "${service_bin}" == "__""service_bin""__" ]]; then
        
        if [[ ${service_background} == "False" ]]; then
            echo "Running  ${service_bin}"
            ${service_bin}
        else
            echo "Running ${service_bin} in the background"
            screen -S ${service_bin}-${job_number} -d -m ${service_bin}
            pid=$(ps -x | grep ${service_bin}-${job_number} | grep -wv grep | awk '{print $1}')
            echo ${pid} >> ${chdir}/service.pid
        fi
        echo "Done"
    fi
fi

sleep 99999
