# Runs via ssh + sbatch
[[ "${DEBUG:-}" == "true" ]] && set -x

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

# code-server-4.92.2-linux-amd64.tar.gz
service_tgz_basename=$(echo ${service_download_url} | rev | cut -d'/' -f1 | rev)
# code-server-4.92.2-linux-amd64
service_tgz_stem=$(echo ${service_tgz_basename} | sed "s|.tar.gz||g")

service_tgz_path=${service_parent_install_dir}/${service_tgz_basename}
service_install_dir=${service_parent_install_dir}/${service_tgz_stem}
service_exec=${service_install_dir}/bin/code-server


# SET DEFAULTS:
if [ -z ${service_directory} ]; then
    service_directory=~/
fi

if [ -z ${service_password} ]; then
    password_flag="--auth=none"
else
    export PASSWORD=${service_password}
    password_flag="--auth=password"
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

# START SERVICE
echo ${juice_cmd} ${service_exec} --bind-addr=${HOSTNAME}:${service_port} ${password_flag} ${service_directory}

${juice_cmd} ${service_exec} \
    --bind-addr=${HOSTNAME}:${service_port} \
    ${gh_flag} \
    ${password_flag} \
    ${service_directory}

if [ $? -ne 0 ]; then
    echo "(date) ERROR: Command failed"
    exit 1
fi

sleep 999999999
# For openvscode-server
${service_exec} \
    --port ${service_port} \
    --without-connection-token \
    --host localhost

