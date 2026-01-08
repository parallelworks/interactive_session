# Runs via ssh + sbatch

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

service_novnc_tgz_stem=$(echo ${service_novnc_tgz_basename} | sed "s|.tar.gz||g" | sed "s|.tgz||g")
service_novnc_install_dir=${service_parent_install_dir}/${service_novnc_tgz_stem}

# ----- REMOVE AFTER V4 IS RELEASED EVERYWHERE ----- #
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

screen_name=webterm${service_port}
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
# ----- REMOVE AFTER V4 IS RELEASED EVERYWHERE ----- #

cd ~/

rm -rf ${PWD}/service.pid

# JUICE https://docs.juicelabs.co/docs/juice/intro
if [[ "${juice_use_juice}" == "true" ]]; then
    echo "INFO: Enabling Juice for remote GPU access"
    if [ -z "${juice_exec}" ]; then
        juice_exec=${service_parent_install_dir}/juice/juice
        echo "INFO: Set Juice executable path to ${juice_exec}"
    fi
    
    if ! [ -z "${juice_vram}" ]; then
        vram_arg="--vram ${juice_vram}"
    fi
    if ! [ -z "${juice_pool_ids}" ]; then
        pool_ids_arg="--pool-ids ${juice_pool_ids}"
    fi
    juice_cmd="${juice_exec} run ${juice_cmd_args} ${vram_arg} ${pool_ids_arg}"
    echo "INFO: Prepared Juice command: ${juice_cmd}"
    echo "INFO: Logging into Juice with provided token"
    ${juice_exec} login -t "${JUICE_TOKEN}" || {
        echo "ERROR: Failed to log into Juice"
        exit 1
    }
fi

set -x
if command -v screen >/dev/null 2>&1; then
    echo "screen -S ${screen_name} -X quit" > ${resource_jobdir}/cancel.sh
    echo "screen -S ${screen_name} -X quit" > ${resource_jobdir}/service-kill-${job_number}-main.sh
    ${juice_cmd} ${service_novnc_install_dir}/ttyd.x86_64 -p "$service_port" -s 2 bash -lc "screen -S ${screen_name} -x || screen -S ${screen_name}"
else
    ${juice_cmd} ${service_novnc_install_dir}/ttyd.x86_64 -p $service_port -s 2 bash &
    pid="$!"
    echo ${pid} >> ${resource_jobdir}/service.pid
    echo "kill ${pid}" >> ${resource_jobdir}/cancel.sh
fi

sleep inf
