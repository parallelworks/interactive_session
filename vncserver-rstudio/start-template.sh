set -x
# Runs via ssh + sbatch
partition_or_controller=__partition_or_controller__
job_number=__job_number__
chdir=__chdir__
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
    novnc_dir=${HOME}/pw/bootstrap/noVNC-1.3.0
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
    displayErrorMessage "ERROR: No service port found in the range \${minPort}-\${maxPort} -- exiting session"
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


# CUSTOM BOOTSTRAP FOR VNCSERVER + RSTUDIO
if  [ -z $(which ${vnc_bin}) ]; then
    echo "INSTALLING TIGERVNC SERVER"
    sudo -n yum install tigervnc-server -y
    sudo -n yum install python3 -y
fi
if  [ -z $(which ${vnc_bin}) ]; then
    displayErrorMessage "ERROR: ${vnc_bin} executable not found - Exiting workflow!"
fi

if  [ -z $(which gnome-session) ]; then
    echo "INSTALLING GNOME DESKTOP"
    sudo -n yum groupinstall "Server with GUI" -y
fi
if  [ -z $(which gnome-session) ]; then
    displayErrorMessage "ERROR: gnome-session executable not found - Exiting workflow!"
fi

if  [ -z $(which rstudio) ]; then
    echo "INSTALLING RSTUDIO"
    sudo -n yum install epel-release -y 
    sudo -n yum install R -y 
    #wget https://download2.rstudio.org/server/centos7/x86_64/rstudio-server-rhel-1.4.1717-x86_64.rpm 
    #sudo -n yum install rstudio-server-rhel-1.4.1717-x86_64.rpm -y
    wget https://download1.rstudio.org/desktop/centos7/x86_64/rstudio-2022.07.2-576-x86_64.rpm
    sudo -n yum install rstudio-2022.07.2-576-x86_64.rpm -y
fi
if  [ -z $(which rstudio) ]; then
    displayErrorMessage "ERROR: rstudio executable not found - Exiting workflow!"
fi

# FIND SERVER EXECUTABLE (BOOTSTRAP)
vnc_exec=$(which ${vnc_bin})

# Start service
${vnc_exec} -kill ${DISPLAY}
${vnc_exec} ${DISPLAY} -SecurityTypes=None

rm -f ${chdir}/service.pid
touch ${chdir}/service.pid

gnome-session &
echo $! > ${chdir}/service.pid


bootstrap_tgz ${novnc_tgz} ${novnc_dir}
cd ${novnc_dir}

echo

screen -S noVNC-${job_number} -d -m ./utils/novnc_proxy --vnc localhost:${displayPort} --listen localhost:${servicePort}
rm -f ${portFile}
pid=$(ps -x | grep noVNC-${job_number} | grep -wv grep | awk '{print $1}')
echo ${pid} >> ${chdir}/service.pid
pid=$(ps -x | grep vnc | grep ${displayPort} | awk '{print $1}')
echo ${pid} >> ${chdir}/service.pid
sleep 5  # Need this specially in controller node or second software won't show up!

echo "Running rstudio in the background"
# Convert: /path/to/bin --and options to bin:
sname=rstudio
screen -S ${sname}-${job_number} -d -m rstudio
pid=$(ps -x | grep ${sname}-${job_number} | grep -wv grep | awk '{print $1}')
echo ${pid} >> ${chdir}/service.pid
echo "Done"
sleep 99999
