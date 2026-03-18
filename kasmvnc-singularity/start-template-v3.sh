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
minPort=5901
maxPort=5999
for port in $(seq ${minPort} ${maxPort} | shuf); do
    displayNumber=${port: -2}
    XdisplayNumber=${displayNumber#0}
    
    # Check if VNC port (5900+display) is in use
    if netstat -aln | grep -q "LISTEN.*:${port}\b" 2>/dev/null; then
        continue
    fi
    
    # Check if X11 TCP port (6000+display) is in use (e.g. SSH X11 forwarding)
    x11Port=$((6000 + XdisplayNumber))
    if netstat -aln | grep -q "LISTEN.*:${x11Port}\b" 2>/dev/null; then
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

# Load singularity/apptainer if not already in PATH
if ! command -v singularity &> /dev/null; then
    if module load apptainer 2>/dev/null; then
        echo "$(date) Loaded apptainer module"
    elif module load singularity 2>/dev/null; then
        echo "$(date) Loaded singularity module"
    else
        echo "$(date) ERROR: singularity/apptainer not found in PATH and could not be loaded via module" >&2
        exit 1
    fi
else
    echo "$(date) singularity already available in PATH"
fi

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
echo "Starting Singularity container..."
touch empty
chmod 644 empty
touch error.log
chmod 666 error.log

# Create a per-job /tmp to avoid cross-user permission conflicts on shared nodes
# (Singularity bind-mounts host /tmp by default; container entrypoint writes /tmp/env.sh)
mkdir -p $PWD/container_tmp
echo "rm -rf $PWD/container_tmp" >> cancel.sh

# Unset host Python/Perl env vars that corrupt the container's runtime
unset PYTHONPATH PYTHONHOME PERL5LIB PERLLIB PERL5OPT


USERNS_FLAG=""
WRITABLE_TMPFS_FLAG=""
if [[ "$(hostname)" == *narwhal* ]]; then
    USERNS_FLAG="--userns"
else
    WRITABLE_TMPFS_FLAG="--writable-tmpfs"
fi

set -x
singularity run \
    ${WRITABLE_TMPFS_FLAG} ${USERNS_FLAG} \
    ${GPU_FLAG} \
    ${MOUNT_FLAGS} \
    --env BASE_PATH="${basepath}" \
    --env NGINX_PORT="${service_port}" \
    --env KASM_PORT=$(pw agent open-port) \
    --env VNC_DISPLAY="${XdisplayNumber}" \
    --bind /etc/passwd:/etc/passwd:ro \
    --bind /etc/group:/etc/group:ro \
    --bind /etc/environment:/etc/environment:ro \
    --bind $PWD/empty:/etc/nginx/conf.d/default.conf \
    --bind $PWD/error.log:/var/log/nginx/error.log \
    --bind $PWD/container_tmp:/tmp \
    "${container_dir}" &

#     --env STARTUP_COMMAND="${startup_command}" \

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

export DISPLAY=":${XdisplayNumber}"
run_xterm_loop | tee -a ${PW_PARENT_JOB_DIR}/xterm.out &
run_xterm_pid=$!
echo "kill ${run_xterm_pid} || true # run_xterm_loop" >> cancel.sh

if [ -n "${startup_command}" ]; then
    echo "$(date) Running startup command: ${startup_command}"
    eval ${startup_command} &
    startup_command_pid=$!
    echo "kill ${startup_command_pid} || true # startup_command" >> cancel.sh
fi

# Wait for container to exit
wait ${kasmvnc_container_pid}
echo "$(date) Exiting job"
kill ${run_xterm_pid}
rm cancel.sh
exit 1

