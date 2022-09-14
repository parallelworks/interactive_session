# Runs via ssh + sbatch

partition_or_controller=__partition_or_controller__
servicePort="__servicePort__"
job_number=__job_number__
job_dir=${PWD}


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

cd ~/

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
chmod +x ./pworks/noVNC-1.3.0/ttyd.x86_64

#screen -wipe
#screen -S tty -d -m  ./pworks/noVNC-1.3.0/ttyd.x86_64 -p $servicePort bash
rm -rf ${job_dir}/service.pid

if [ -z "$(which screen)" ]; then
    ./pworks/noVNC-1.3.0/ttyd.x86_64 -p $servicePort bash &
    echo $! >> ${job_dir}/service.pid
else
    screen -S tty-${job_number} -d -m ./pworks/noVNC-1.3.0/ttyd.x86_64 -p $servicePort bash
    pid=$(ps -x | grep tty-${job_number} | grep -wv grep | awk '{print $1}')
    echo ${pid} >> ${job_dir}/service.pid
fi

sleep 99999