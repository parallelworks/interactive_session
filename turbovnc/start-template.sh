# Runs via ssh + sbatch
partition_or_controller=__partition_or_controller__
job_number=__job_number__
slurm_module=__slurm_module__
service_bin="$(echo __service_bin__  | sed "s|---| |g")"
service_background=__service_background__ # Launch service as a background process (! or screen)
chdir=__chdir__
server_exec=__server_exec__
# Order of priority for server_exec:
# 1. Whatever is in the ${PATH}
# 2. __server_exec__ (hidden parameter)
# 3. install_paths
install_paths="${HOME}/pworks/*/bin /opt/*/bin /shared/*/bin"


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
HERE

#printf "password\npassword\n\n" | vncpasswd

if [ ! -f ${HOME}/.vnc/passwd ]; then
    mkdir -p ${HOME}/.vnc
    echo headless | /opt/TurboVNC/bin/vncpasswd -f > ${HOME}/.vnc/passwd
    chown -R $USER:$USER ${HOME}/.vnc
    chmod 0600 ${HOME}/.vnc/passwd
fi

echo
set -x

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

# Find vncserver executable:
if ! [ -z $(which vncserver) ]; then
    server_exec=$(which vncserver)
elif [ -z ${server_exec} ] || [[ "${server_exec}" == "__""server_exec""__" ]]; then
    server_exec=$(find ${install_paths} -maxdepth 1 -mindepth 1 -name vncserver  2>/dev/null | head -n1)
fi

if [ ! -f "${server_exec}" ]; then
    echo ERROR: server_exec=${server_exec} file not found! - Existing workflow!
    exit 1
fi

# Start service
${server_exec} -kill ${DISPLAY}
${server_exec} ${DISPLAY}

rm -f ${chdir}/service.pid
touch ${chdir}/service.pid

DESKTOP_CMD="mate-session"

if [ -z $(which $DESKTOP_CMD) ]; then
    echo "WARNING: vnc desktop not found!"
else
    $DESKTOP_CMD &
    echo $! > ${chdir}/service.pid
fi

# BOOTSTRAP CODE --> FIXME: Cannot be generalized for different versions in different systems!
install_dir=${HOME}/pworks/noVNC-1.3.0
tgz_path=/swift-pw-bin/apps/noVNC-1.3.0.tgz
# Check if the code directory is present
# - if not copy from user container -> /swift-pw-bin/noVNC-1.3.0.tgz
if ! [ -d "${install_dir}" ]; then
    echo "Bootstrapping ${install_dir}"
    mkdir -p ~/pworks

    # first check if the noVNC file is available on the node
    if [[ -f "/core/pworks-main/${tgz_path}" ]]; then
        cp /core/pworks-main/${tgz_path} ~/pworks
    else
        ssh_options="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
        if [[ ${partition_or_controller} == "True" ]]; then
            # Running in a compute partition
            if [[ "$USERMODE" == "k8s" ]]; then
                # HAVE TO DO THIS FOR K8S NETWORKING TO EXPOSE THE PORT
                # WARNING: Maybe if controller contains user name (user@ip) you need to extract only the ip
                # Works because home directory is shared!
                ssh ${ssh_options} $masterIp scp ${USER_CONTAINER_HOST}:${tgz_path} ~/pworks
            else # Docker mode
                # Works because home directory is shared!
                ssh ${ssh_options} $masterIp scp ${USER_CONTAINER_HOST}:${tgz_path} ~/pworks
            fi
        else
            # Running in a controller node
            if [[ "$USERMODE" == "k8s" ]]; then
                # HAVE TO DO THIS FOR K8S NETWORKING TO EXPOSE THE PORT
                # WARNING: Maybe if controller contains user name (user@ip) you need to extract only the ip
                scp ${USER_CONTAINER_HOST}:${tgz_path} ~/pworks
            else # Docker mode
                scp ${USER_CONTAINER_HOST}:${tgz_path} ~/pworks
            fi
        fi

    fi
    tar -zxf ~/pworks/$(basename ${tgz_path}) -C ~/pworks
fi
cd  ~/pworks/noVNC-1.3.0

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
