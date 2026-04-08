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
    
    # Check for X11 socket/lock files (filesystem and abstract Unix domain sockets)
    # Abstract sockets are held in kernel namespace and won't appear under /tmp/.X11-unix/
    # but are visible via ss -xl; Singularity shares the host network namespace so the
    # container would collide with them.
    if [ -e "/tmp/.X11-unix/X${XdisplayNumber}" ] || [ -e "/tmp/.X${XdisplayNumber}-lock" ]; then
        continue
    fi
    if ss -xl 2>/dev/null | grep -qE "\.X11-unix/X${XdisplayNumber}$"; then
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

mount_directories="${HOME} /p/work /p/work1 /p/app /p/cwfs /scratch /run/munge /etc/pbs.conf /var/spool/pbs /opt/pbs ${container_mount_paths}"

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

# Unset host env vars that corrupt the container's runtime.
# On Cray EX systems, LD_LIBRARY_PATH carries PE paths (libsci, mpich, cce) that
# cause Python/Perl inside the container to load incompatible native libraries.
# PYTHONSTARTUP points to a host file that doesn't exist in the container.
unset PYTHONPATH PYTHONHOME PERL5LIB PERLLIB PERL5OPT PYTHONSTARTUP LD_LIBRARY_PATH

# Only bind /etc/environment if it's safe (simple key=value, no shell control flow).
# Some systems have shell syntax in /etc/environment that breaks Singularity's 95-apps.sh.
ETC_ENV_FLAG=""
if [ -f /etc/environment ] && ! grep -qE '^\s*(if|for|while|case|do|then|function)\b' /etc/environment 2>/dev/null; then
    ETC_ENV_FLAG="--bind /etc/environment:/etc/environment:ro"
else
    echo "$(date) WARNING: Skipping /etc/environment bind (file missing or contains shell syntax)"
fi


USERNS_FLAG=""
WRITABLE_TMPFS_FLAG=""
if [[ "$(hostname)" == *narwhal* ]]; then
    USERNS_FLAG="--userns"
else
    WRITABLE_TMPFS_FLAG="--writable-tmpfs"
fi

export TMPDIR=${PWD}/tmp
export SINGULARITY_TMPDIR=${PWD}/tmp
mkdir -p ${PWD}/tmp
mkdir -p $PWD/container_tmp

set -x
singularity run \
    ${WRITABLE_TMPFS_FLAG} ${USERNS_FLAG} ${ETC_ENV_FLAG} \
    ${GPU_FLAG} \
    ${MOUNT_FLAGS} \
    --env XAUTHORITY=/tmp/.Xauthority \
    --env DISPLAY=":${XdisplayNumber}" \
    --env BASE_PATH="${basepath}" \
    --env NGINX_PORT="${service_port}" \
    --env KASM_PORT=$(pw agent open-port) \
    --env VNC_DISPLAY="${XdisplayNumber}" \
    --bind /etc/passwd:/etc/passwd:ro \
    --bind /etc/group:/etc/group:ro \
    --bind $PWD/empty:/etc/nginx/conf.d/default.conf \
    --bind $PWD/error.log:/var/log/nginx/error.log \
    --bind $PWD/container_tmp:/tmp \
    "${container_dir}" &

#     --env STARTUP_COMMAND="${startup_command}" \

kasmvnc_container_pid=$!
set +x

echo "kill ${kasmvnc_container_pid} #kasmvnc_container_pid" >> cancel.sh
echo "chmod -R u+rwX ${container_dir}" >> cancel.sh
echo "KasmVNC container started with PID ${kasmvnc_container_pid}"

sleep 45  # Allow container to start

xauthority_file=$(find container_tmp -name .Xauthority 2>/dev/null | head -1)
if [ -n "${xauthority_file}" ]; then
    export XAUTHORITY="${PWD}/${xauthority_file}"
    echo "$(date): Setting XAUTHORITY to ${XAUTHORITY}"
fi

xterm_cmd="$(which xterm 2>/dev/null || echo ${service_parent_install_dir}/xterm)"
export DISPLAY=":${XdisplayNumber}"
run_xterm_loop(){
    while true; do
        echo "$(date): Starting xterm with ${xterm_cmd}"
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

