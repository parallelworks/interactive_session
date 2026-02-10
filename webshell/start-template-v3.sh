# Runs via ssh + sbatch

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

service_novnc_tgz_stem=$(echo ${service_novnc_tgz_basename} | sed "s|.tar.gz||g" | sed "s|.tgz||g")
service_novnc_install_dir=${service_parent_install_dir}/${service_novnc_tgz_stem}

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
    echo "screen -S ${screen_name} -X quit" > ${PW_PARENT_JOB_DIR}/cancel.sh
    echo "screen -S ${screen_name} -X quit" > ${PW_PARENT_JOB_DIR}/service-kill-${job_number}-main.sh
    ${juice_cmd} ${service_novnc_install_dir}/ttyd.x86_64 -p "$service_port" -s 2 bash -lc "screen -S ${screen_name} -x || screen -S ${screen_name}"
else
    ${juice_cmd} ${service_novnc_install_dir}/ttyd.x86_64 -p $service_port -s 2 bash &
    pid="$!"
    echo ${pid} >> ${PW_PARENT_JOB_DIR}/service.pid
    echo "kill ${pid}" >> ${PW_PARENT_JOB_DIR}/cancel.sh
fi

sleep inf
