# Runs via ssh + sbatch
[[ "${DEBUG:-}" == "true" ]] && set -x


if [ -z "${service_load_env}" ]; then
    service_conda_sh=${service_parent_install_dir}/${service_conda_install_dir}/etc/profile.d/conda.sh
    service_load_env="source ${service_conda_sh}; conda activate ${service_conda_env}"
fi

if [[ "${service_conda_install}" == "true" ]]; then
    source ${service_conda_sh}
    eval "conda activate ${service_conda_env}"
else
    eval "${service_load_env}"
fi


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

date

if ! [ -z "${service_script}" ]; then
    ${juice_cmd} marimo ${service_mode} ${service_script} --port ${service_port} --host ${HOSTNAME} --no-token
else
    ${juice_cmd} marimo tutorial intro --port ${service_port} --no-token --host ${HOSTNAME}
fi

sleep inf
