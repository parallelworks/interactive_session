# Runs via ssh + sbatch

partition_or_controller=__partition_or_controller__
servicePort="__servicePort__"

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

screen -wipe
screen -S tty -d -m  ./pworks/noVNC-1.3.0/ttyd.x86_64 -p $servicePort bash

sleep 9999
