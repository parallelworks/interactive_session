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

sudo systemctl start docker || true

# Detect docker command and ensure the service is running
if docker info &>/dev/null; then
    docker_cmd="docker"
    echo "Docker is accessible without sudo"
elif sudo docker info &>/dev/null; then
    docker_cmd="sudo docker"
    echo "Docker requires sudo"
else
    echo "$(date) ERROR: Docker is not available on this system" >&2
    exit 1
fi
echo "Using docker command: ${docker_cmd}"

echo "$(date) Starting KasmVNC Container ..."

# GPU flag
GPU_FLAG=""
if [[ "${enable_gpu}" == "true" ]]; then
    GPU_FLAG="--gpus all"
    echo "GPU support enabled (--gpus all)"
else
    echo "GPU support disabled"
fi

container_image="parallelworks/kasmvnc-${kasmvnc_os}"
container_name="kasmvnc-${USER}-${XdisplayNumber}"

mount_directories="/p/home /p/work /p/work1 /p/app /p/cwfs /scratch /run/munge /etc/pbs.conf /var/spool/pbs /opt/pbs ${container_mount_paths}"

# Function to build mount flags for existing directories
build_mount_flags() {
    local directories="$1"
    local flags=""

    for dir in ${directories}; do
        if [ -e "${dir}" ]; then
            flags="${flags} -v ${dir}:${dir}"
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
echo "Starting Docker container..."
touch empty
chmod 644 empty
touch error.log
chmod 666 error.log
set -x
${docker_cmd} run \
    --rm \
    --name "${container_name}" \
    --network host \
    ${GPU_FLAG} \
    ${MOUNT_FLAGS} \
    -e BASE_PATH="${basepath}" \
    -e NGINX_PORT="${service_port}" \
    -e KASM_PORT=$(pw agent open-port) \
    -e VNC_DISPLAY="${XdisplayNumber}" \
    -e STARTUP_COMMAND="${startup_command}" \
    -v /etc/passwd:/etc/passwd:ro \
    -v /etc/group:/etc/group:ro \
    -v /etc/environment:/etc/environment:ro \
    -v $PWD/empty:/etc/nginx/conf.d/default.conf \
    -v $PWD/error.log:/var/log/nginx/error.log \
    "${container_image}" &

kasmvnc_container_pid=$!
set +x

echo "${docker_cmd} stop ${container_name} #kasmvnc_container" >> cancel.sh
echo "kill ${kasmvnc_container_pid} #kasmvnc_container_pid" >> cancel.sh
echo "KasmVNC container started with PID ${kasmvnc_container_pid}"

sleep 6  # Allow container to start

echo "Starting xterm on the host..."
${docker_cmd} cp ${container_name}:/home/packer/.Xauthority /tmp/.xauth${XdisplayNumber}
sudo chown ${USER} /tmp/.xauth${XdisplayNumber} || true
export XAUTHORITY=/tmp/.xauth${XdisplayNumber}

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

