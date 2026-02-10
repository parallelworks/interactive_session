################################################################################
# Interactive Session Service Starter - WebShell (ttyd terminal)
#
# Purpose: Start ttyd web terminal service on allocated port
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - service_port: Allocated port (from session_runner)
#   - service_parent_install_dir: Installation directory
#   - service_novnc_tgz_basename: noVNC tarball (contains ttyd binary)
#   - screen_name: Screen session name (if screen is available)
#   - job_number: Job number for service tracking
#   - juice_use_juice: Enable Juice for remote GPU access (optional)
################################################################################

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

service_novnc_tgz_stem=$(echo ${service_novnc_tgz_basename} | sed "s|.tar.gz||g" | sed "s|.tgz||g")
service_novnc_install_dir=${service_parent_install_dir}/${service_novnc_tgz_stem}

cd ~/

rm -rf ${PWD}/service.pid

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

set -x
# Start ttyd terminal service
# -p: port number, -s: signal to send on exit (2=SIGINT for graceful shutdown)
if command -v screen >/dev/null 2>&1; then
    echo "screen -S ${screen_name} -X quit" > ${PW_PARENT_JOB_DIR}/cancel.sh
    echo "screen -S ${screen_name} -X quit" > ${PW_PARENT_JOB_DIR}/service-kill-${job_number}-main.sh
    ${juice_cmd} ${service_novnc_install_dir}/ttyd.x86_64 -p "$service_port" -s 2 bash -lc "screen -S ${screen_name} -x || screen -S ${screen_name}"
else
    ${juice_cmd} ${service_novnc_install_dir}/ttyd.x86_64 -p "${service_port}" -s 2 bash &
    pid="$!"
    echo ${pid} >> ${PW_PARENT_JOB_DIR}/service.pid
    echo "kill ${pid}" >> ${PW_PARENT_JOB_DIR}/cancel.sh
fi

# Keep container alive indefinitely
# Using 'inf' which is bash-specific shorthand for infinity
sleep inf
