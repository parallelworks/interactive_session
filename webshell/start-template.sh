# Runs via ssh + sbatch

# Prepare kill service script
# - Needs to be here because we need the hostname of the compute node.
# - kill-template.sh --> service-kill-${job_number}.sh --> service-kill-${job_number}-main.sh

if [[ ${jobschedulertype} == "CONTROLLER" ]]; then
    echo "bash ${PWD}/service-kill-${job_number}-main.sh" > service-kill-${job_number}.sh
else
    # Remove .cluster.local for einteinmed!
    hname=$(hostname | sed "s/.cluster.local//g")
    echo "ssh ${hname} 'bash -s' < ${PWD}/service-kill-${job_number}-main.sh" > service-kill-${job_number}.sh
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
# - if not copy from user container -> /swift-pw-bin/apps/noVNC-1.3.0.tgz
if ! [ -d "$(echo ~/pw/noVNC-1.3.0)" ]; then
    echo "Bootstrapping noVNC"
    set -x
    mkdir -p ~/pw
    rsync -avzq -e "ssh ${resource_ssh_usercontainer_options}" ${USER_CONTAINER_HOST}:/swift-pw-bin/apps/noVNC-1.3.0.tgz ~/pw
    tar -zxf ~/pw/noVNC-1.3.0.tgz -C ~/pw
    set +x
fi
chmod +x ./pw/noVNC-1.3.0/ttyd.x86_64

rm -rf ${PWD}/service.pid

./pw/noVNC-1.3.0/ttyd.x86_64 -p $servicePort bash &
echo $! >> ${PWD}/service.pid

# Notify platform that service is running
${sshusercontainer} ${pw_job_dir}/utils/notify.sh

sleep 99999