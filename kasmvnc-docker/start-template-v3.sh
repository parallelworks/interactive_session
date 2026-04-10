#!/bin/bash
# start.sh - Desktop Startup Script (runs on compute node)
#
# It uses resources prepared by setup.sh which runs in STEP 1 on the controller.

set -ex

echo "::group::Desktop Service Starting (Compute Node)"

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

container_dir=${service_parent_install_dir}/kasmvnc-${kasmvnc_os}

# Initialize cancel script
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh

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
    echo "::notice::Docker is accessible without sudo"
elif sudo docker info &>/dev/null; then
    docker_cmd="sudo docker"
    echo "::notice::Docker requires sudo"
else
    echo "::error title=Error::Docker is not available on this system"
    exit 1
fi
echo "::notice::Using docker command: ${docker_cmd}"

echo "::notice::Starting KasmVNC Container..."

# GPU flag
GPU_FLAG=""
if [[ "${enable_gpu}" == "true" ]]; then
    GPU_FLAG="--gpus all"
    echo "::notice::GPU support enabled (--gpus all)"
else
    echo "::notice::GPU support disabled"
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
            echo "::debug::Mount: ${dir} exists, adding to bind mounts" >&2
        else
            echo "::debug::Mount: ${dir} does not exist, skipping" >&2
        fi
    done

    echo "${flags}"
}

# Build mount flags for existing directories
MOUNT_FLAGS=$(build_mount_flags "${mount_directories}")
echo "::debug::Mount flags: ${MOUNT_FLAGS}"

# Pull KasmVNC container
echo "::notice::Pulling Docker container..."
${docker_cmd} pull "${container_image}"

# Start KasmVNC container
echo "::notice::Starting Docker container..."
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
    -v /etc/environment:/etc/environment:ro \
    -v $PWD/empty:/etc/nginx/conf.d/default.conf \
    -v $PWD/error.log:/var/log/nginx/error.log \
    "${container_image}" &

#     -e STARTUP_COMMAND="${startup_command}" \

kasmvnc_container_pid=$!
set +x

echo "${docker_cmd} stop ${container_name} #kasmvnc_container" >> cancel.sh
echo "kill ${kasmvnc_container_pid} | true #kasmvnc_container_pid" >> cancel.sh
echo "::notice::KasmVNC container started with PID ${kasmvnc_container_pid}"

echo "::notice::Copying .Xauthority from container to host..."
for i in $(seq 1 30); do
    if ${docker_cmd} cp "${container_name}:/home/packer/.Xauthority" "/tmp/.xauth${XdisplayNumber}" \
       || ${docker_cmd} cp "${container_name}:/home/metauser/.Xauthority" "/tmp/.xauth${XdisplayNumber}"
    then
        break
    fi
    echo "::debug::Attempt $i/30 failed, retrying in 2s..."
    sleep 2
done
sudo chown "$USER" "/tmp/.xauth${XdisplayNumber}" || chown "$USER" "/tmp/.xauth${XdisplayNumber}"
echo "rm /tmp/.xauth${XdisplayNumber}" >> cancel.sh
export XAUTHORITY=/tmp/.xauth${XdisplayNumber}

xterm_cmd="$(which xterm 2>/dev/null || echo ${service_parent_install_dir}/xterm)"
echo "::notice::Starting xterm on the host..."
run_xterm_loop(){
    while true; do
        echo "::debug::Starting xterm with ${xterm_cmd}"
        ${xterm_cmd} -fa "DejaVu Sans Mono" -fs 12 -e bash -c '
printf "\033[1;36m"
printf "╔══════════════════════════════════════════════════════════════╗\n"
printf "║              Welcome to your Remote Desktop Session          ║\n"
printf "╚══════════════════════════════════════════════════════════════╝\n"
printf "\033[0m\n"
printf "\033[1mThis terminal runs directly on the cluster node\033[0m — not inside the\n"
printf "desktop environment. If you close it, it will automatically reopen.\n\n"
printf "\033[1mThe desktop you see in your browser runs inside a container\033[0m\n"
printf "(an isolated software environment). Applications started from\n"
printf "this terminal run on the host node instead.\n\n"
printf "\033[1mTip:\033[0m You can launch host applications here. The \033[1m&\033[0m keeps your\n"
printf "terminal free while the app runs. Example:\n\n"
printf "  \033[1;32mfirefox &\033[0m\n\n"
printf "────────────────────────────────────────────────────────────────\n\n"
exec bash'
        sleep 1
    done
}

run_xterm_loop | tee -a ${PW_PARENT_JOB_DIR}/xterm.out &
run_xterm_pid=$!
echo "kill ${run_xterm_pid} | true # run_xterm_loop" >> cancel.sh

if [ -n "${startup_command}" ]; then
    echo "::notice::Running startup command: ${startup_command}"
    eval ${startup_command} &
    startup_command_pid=$!
    echo "kill ${startup_command_pid} | true # startup_command" >> cancel.sh
fi

# Wait for container to exit
wait ${kasmvnc_container_pid}
echo "::notice::Exiting job"
echo "::endgroup::"
kill ${run_xterm_pid}
bash cancel.sh
exit 1

