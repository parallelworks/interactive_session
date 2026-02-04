#!/bin/bash
# start.sh - Desktop Startup Script (runs on compute node)
#
# It uses resources prepared by setup.sh which runs in STEP 1 on the controller.

set -e

echo "=========================================="
echo "Desktop Service Starting (Compute Node)"
echo "=========================================="

# =============================================================================
# Source inputs and verify setup
# =============================================================================
# Normalize job directory path (remove trailing slash if present)
JOB_DIR="${PW_PARENT_JOB_DIR%/}"

# Ensure we're working from the job directory
cd "${JOB_DIR}"

# Initialize cancel script
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh
echo "mv cancel.sh cancel.sh.executed" >> cancel.sh

# Find an available display port
minPort=5901
maxPort=5999
for port in $(seq ${minPort} ${maxPort} | shuf); do
    out=$(netstat -aln | grep LISTEN | grep ${port})
    displayNumber=${port: -2}
    XdisplayNumber=$(echo ${displayNumber} | sed 's/^0*//')
    if [ -z "${out}" ] && ! [ -e /tmp/.X11-unix/X${XdisplayNumber} ] && ! [ -e /tmp/.X${XdisplayNumber}-lock ]; then
        # To prevent multiple users from using the same available port --> Write file to reserve it
        portFile=/tmp/${port}.port.used
        if ! [ -f "${portFile}" ]; then
            touch ${portFile}
            echo "rm ${portFile}" >> cancel.sh
            export displayPort=${port}
            export DISPLAY=:${displayNumber#0}
            break
        fi
    fi
done

# =============================================================================
# KasmVNC Container Mode
# =============================================================================

echo "Starting KasmVNC Container Mode..."

# Read container path
if [ -f "${JOB_DIR}/KASMVNC_CONTAINER_PATH" ]; then
    KASMVNC_CONTAINER_SIF=$(cat "${JOB_DIR}/KASMVNC_CONTAINER_PATH")
else
    echo "ERROR: KASMVNC_CONTAINER_PATH not found" >&2
    exit 1
fi

# Verify container exists
if [ ! -f "${KASMVNC_CONTAINER_SIF}" ]; then
    echo "ERROR: KasmVNC container not found at ${KASMVNC_CONTAINER_SIF}" >&2
    exit 1
fi
echo "Using container: ${KASMVNC_CONTAINER_SIF}"

# Read GPU setting
enable_gpu="true"
if [ -f "${JOB_DIR}/KASMVNC_CONTAINER_ENABLE_GPU" ]; then
    enable_gpu=$(cat "${JOB_DIR}/KASMVNC_CONTAINER_ENABLE_GPU")
fi

# GPU flag
GPU_FLAG=""
if [[ "${enable_gpu}" == "true" ]]; then
    GPU_FLAG="--nv"
    echo "GPU support enabled (--nv)"
else
    echo "GPU support disabled"
fi

# Cleanup function for KasmVNC container mode
cleanup() {
    echo "$(date) Stopping KasmVNC container..."
    if [ -n "${kasmvnc_container_pid:-}" ]; then
        kill ${kasmvnc_container_pid} 2>/dev/null || true
    fi
    if [ -n "${run_xterm_pid:-}" ]; then
        kill ${run_xterm_pid} 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# Start KasmVNC container
echo "Starting Singularity container..."
singularity run \
    ${GPU_FLAG} \
    --env DISPLAY=${DISPLAY} \
    --env BASE_PATH="${basepath}" \
    --env NGINX_PORT="${service_port}" \
    --env KASM_PORT=8590 \
    --bind /etc/passwd:/etc/passwd:ro \
    --bind /etc/group:/etc/group:ro \
    "${KASMVNC_CONTAINER_SIF}" &

kasmvnc_container_pid=$!
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

run_xterm_loop | tee -a ${resource_jobdir}/xterm.out &
run_xterm_pid=$!
echo "kill ${run_xterm_pid} # run_xterm_loop" >> cancel.sh

# Wait for container to exit
wait ${kasmvnc_container_pid}

