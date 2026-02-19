#!/bin/bash
# start.sh - Desktop Startup Script (runs on compute node)
#
# It uses resources prepared by setup.sh which runs in STEP 1 on the controller.

set -ex

echo "=========================================="
echo "Desktop Service Starting (Compute Node)"
echo "=========================================="

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

container_dir=${service_parent_install_dir}/kasmvnc-${kasmvnc_os}

# Initialize cancel script
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh
echo "mv cancel.sh cancel.sh.executed" >> cancel.sh

# Find an available display port
# Find an available display port
minPort=5901
maxPort=5999
for port in $(seq ${minPort} ${maxPort} | shuf); do
    displayNumber=${port: -2}
    XdisplayNumber=${displayNumber#0}
    
    # Check if port is in use (use || true to prevent exit on no match)
    if netstat -aln | grep -q "LISTEN.*:${port}\b" 2>/dev/null; then
        continue
    fi
    
    # Check for X11 socket/lock files
    if [ -e "/tmp/.X11-unix/X${XdisplayNumber}" ] || [ -e "/tmp/.X${XdisplayNumber}-lock" ]; then
        continue
    fi
    
    # To prevent multiple users from using the same available port --> Write file to reserve it
    portFile="/tmp/${port}.port.used"
    if [ -f "${portFile}" ]; then
        continue
    fi
    
    touch "${portFile}"
    echo "rm ${portFile}" >> cancel.sh
    export displayPort=${port}
    export DISPLAY=":${XdisplayNumber}"
    break
done

echo "$(date) Starting KasmVNC Container ..."

# GPU flag
GPU_FLAG=""
if [[ "${enable_gpu}" == "true" ]]; then
    GPU_FLAG="--nv"
    echo "GPU support enabled (--nv)"
else
    echo "GPU support disabled"
fi

mount_directories="/p/home /p/work /p/work1 /p/app /p/cwfs /scratch /run/munge /etc/pbs.conf /var/spool/pbs /opt/pbs ${container_mount_paths}"

# Function to build mount flags for existing directories
build_mount_flags() {
    local directories="$1"
    local flags=""

    for dir in ${directories}; do
        if [ -e "${dir}" ]; then
            flags="${flags} --bind ${dir}"
            echo "Mount: ${dir} exists, adding to bind mounts"  >&2
        else
            echo "Mount: ${dir} does not exist, skipping"  >&2
        fi
    done

    echo "${flags}"
}

# Build mount flags for existing directories
MOUNT_FLAGS=$(build_mount_flags "${mount_directories}")
echo "Mount flags: ${MOUNT_FLAGS}"

# Start KasmVNC container
echo "$(date) Starting Singularity container..."
touch empty
chmod 644 empty
touch error.log
chmod 666 error.log
set -x
echo "$(date): HOME=${HOME}"
singularity run \
    --writable-tmpfs \
    ${GPU_FLAG} \
    ${MOUNT_FLAGS} \
    --home ${HOME} \
    --env BASE_PATH="${basepath}" \
    --env NGINX_PORT="${service_port}" \
    --env KASM_PORT=$(pw agent open-port) \
    --env VNC_DISPLAY="${XdisplayNumber}" \
    --env STARTUP_COMMAND="${startup_command}" \
    --bind /etc/passwd:/etc/passwd:ro \
    --bind /etc/group:/etc/group:ro \
    --bind /etc/environment:/etc/environment:ro \
    --bind $PWD/empty:/etc/nginx/conf.d/default.conf \
    --bind $PWD/error.log:/var/log/nginx/error.log \
    "${container_dir}" &

kasmvnc_container_pid=$!
set +x

echo "kill ${kasmvnc_container_pid} #kasmvnc_container_pid" >> cancel.sh
echo "KasmVNC container started with PID ${kasmvnc_container_pid}"

sleep 6  # Allow container to start

run_xterm_loop(){
    while true; do
        echo "$(date): Starting xterm"
        ${service_parent_install_dir}/xterm -fa "DejaVu Sans Mono" -fs 12
        sleep 1
    done
}

run_xterm_loop | tee -a ${PW_PARENT_JOB_DIR}/xterm.out &
run_xterm_pid=$!
echo "kill ${run_xterm_pid} # run_xterm_loop" >> cancel.sh

# Wait for container to exit
wait ${kasmvnc_container_pid}
echo "$(date) Exiting job"
kill ${run_xterm_pid}
rm cancel.sh
exit 1

