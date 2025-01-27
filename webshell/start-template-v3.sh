# Runs via ssh + sbatch

if [ -z ${service_novnc_parent_install_dir} ]; then
    service_novnc_parent_install_dir=${HOME}/pw/software
fi

service_novnc_tgz_stem=$(echo ${service_novnc_tgz_basename} | sed "s|.tar.gz||g" | sed "s|.tgz||g")
service_novnc_install_dir=${service_novnc_parent_install_dir}/${service_novnc_tgz_stem}

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

rm -rf ${PWD}/service.pid

${service_novnc_install_dir}/ttyd.x86_64 -p $service_port -m 1 bash &
echo $! >> ${PWD}/service.pid

sleep 99999