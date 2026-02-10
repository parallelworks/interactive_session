################################################################################
# Interactive Session Service Starter - OpenVSCode (code-server)
#
# Purpose: Start code-server web service on allocated port
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - service_port: Allocated port (from session_runner)
#   - service_parent_install_dir: Installation directory
#   - service_download_url: Download URL for code-server
#   - service_password: Access password (optional, auth=none if not set)
#   - service_directory: Working directory to open (default: ~/)
#   - juice_use_juice: Enable Juice for remote GPU access (optional)
################################################################################

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
juice_cmd=""  # Initialize to empty
if [[ "${juice_use_juice}" == "true" ]]; then
    echo "$(date) INFO: Enabling Juice for remote GPU access"
    if [ -z "${juice_exec}" ]; then
        juice_exec=${service_parent_install_dir}/juice/juice
        echo "$(date) INFO: Set Juice executable path to ${juice_exec}"
    fi
    
    if ! [ -z "${juice_vram}" ]; then
        vram_arg="--vram ${juice_vram}"
    fi
    if ! [ -z "${juice_pool_ids}" ]; then
        pool_ids_arg="--pool-ids ${juice_pool_ids}"
    fi
    juice_cmd="${juice_exec} run ${juice_cmd_args} ${vram_arg} ${pool_ids_arg}"
    echo "$(date) INFO: Prepared Juice command: ${juice_cmd}"
    echo "$(date) INFO: Logging into Juice with provided token"
    ${juice_exec} login -t "${JUICE_TOKEN}" || {
        echo "$(date) ERROR: Failed to log into Juice" >&2
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
    echo "$(date) ERROR: Command failed" >&2
    exit 1
fi

# Keep container alive indefinitely (999999999 seconds ≈ 31 years)
# Using numeric value instead of 'infinity' for broader compatibility
sleep 999999999
