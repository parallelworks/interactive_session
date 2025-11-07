# Runs via ssh + sbatch
set -x

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


if ! [ -z "${service_script}" ]; then
    ${juice_cmd} marimo ${service_mode} ${service_script} --port ${service_port}
else
    ${juice_cmd} marimo tutorial intro
fi

sleep inf
