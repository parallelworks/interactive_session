#!/bin/bash
################################################################################
# Interactive Session Service Starter - KasmVNC Container Desktop
#
# Purpose: Start KasmVNC containerized desktop service on allocated port
# Runs on: Controller or compute node
# Called by: session_runner after controller setup
#
# Required Environment Variables (provided by session_runner):
#   - service_port: Allocated port for the service
#
# Optional Environment Variables:
#   - kasmvnc_container_runtime: Container runtime (singularity/enroot, default: singularity)
#   - kasmvnc_container_path: Path to container (for singularity)
#   - kasmvnc_enroot_dir: Directory for enroot containers
#   - kasmvnc_os: OS flavor (rocky9/rocky8/ubuntu, default: rocky9)
#   - kasmvnc_enable_gpu: Enable GPU support (true/false, default: true)
#   - container_mount_paths: Newline-separated list of paths to mount
#   - startup_command: Command to run after desktop starts
################################################################################

set -e

echo "=========================================="
echo "KasmVNC Container Desktop Starting"
echo "=========================================="

# =============================================================================
# Configuration
# =============================================================================
CONTAINER_DIR="${HOME}/pw/singularity"
container_runtime="${kasmvnc_container_runtime:-singularity}"
echo "Container runtime: ${container_runtime}"
echo "Service port: ${service_port}"

# =============================================================================
# Shared utility: build mount flags from newline-delimited paths
# =============================================================================
build_mount_flags() {
    local runtime="$1"
    local paths="$2"
    local flags=""

    if [ -z "${paths}" ]; then
        echo ""
        return 0
    fi

    echo "${paths}" | while IFS= read -r mount_path || [ -n "${mount_path}" ]; do
        # Skip empty lines and comments
        mount_path=$(echo "${mount_path}" | xargs)
        [ -z "${mount_path}" ] && continue
        [[ "${mount_path}" == \#* ]] && continue

        # Skip paths that don't exist on this system
        if [ ! -e "${mount_path}" ]; then
            echo "  Skip (not found): ${mount_path}" >&2
            continue
        fi

        if [ "${runtime}" = "enroot" ]; then
            flags="${flags} -m ${mount_path}:${mount_path}"
        else
            flags="${flags} --bind ${mount_path}:${mount_path}"
        fi
        echo "  Mount: ${mount_path}" >&2
    done

    echo "${flags}"
}

# =============================================================================
# Port Allocation
# =============================================================================
# Get KasmVNC internal websocket port
kasm_port=$(pw agent open-port)
if [ -z "${kasm_port}" ]; then
    echo "ERROR: Failed to allocate KasmVNC port" >&2
    exit 1
fi
echo "KasmVNC websocket port: ${kasm_port}"

# Find available VNC display (5901-5999 range)
find_available_vnc_display() {
    # Get listening ports once (try ss first, fall back to netstat)
    local listening
    listening=$(ss -tuln 2>/dev/null || netstat -tuln 2>/dev/null || echo "")

    for display_num in $(seq 1 99 | shuf); do
        local port=$((5900 + display_num))
        # Check port is not in use
        if echo "${listening}" | grep -q ":${port} "; then
            continue
        fi
        # Check no Xvnc process is running on this display
        if pgrep -u $(whoami) -f "Xvnc.*:${display_num}( |$)" >/dev/null 2>&1; then
            continue
        fi
        echo "${display_num}"
        return 0
    done
    echo "1"  # Fallback to :1
}

vnc_display=$(find_available_vnc_display)
echo "VNC display: :${vnc_display}"

# Force-clean the selected display (remove any leftover artifacts)
pkill -u $(whoami) -f "Xvnc.*:${vnc_display}( |$)" 2>/dev/null || true
rm -f "/tmp/.X11-unix/X${vnc_display}" "/tmp/.X${vnc_display}-lock" 2>/dev/null || true

# Build BASE_PATH for the container
BASE_PATH="/me/session/${PW_USER}/${PW_JOB_ID}/"
echo "BASE_PATH: ${BASE_PATH}"

# =============================================================================
# Cleanup function
# =============================================================================
cleanup_kasmvnc_container() {
    echo "$(date) Stopping KasmVNC container..."
    if [ -n "${kasmvnc_container_pid:-}" ]; then
        kill ${kasmvnc_container_pid} 2>/dev/null || true
    fi
    # Clean up VNC display
    pkill -u $(whoami) -f "Xvnc.*:${vnc_display}" 2>/dev/null || true
    rm -f "/tmp/.X11-unix/X${vnc_display}" "/tmp/.X${vnc_display}-lock" 2>/dev/null || true
}

# Create cancel.sh for service cleanup
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh

trap cleanup_kasmvnc_container EXIT INT TERM

# =============================================================================
# Build mount flags
# =============================================================================
MOUNT_FLAGS=""
if [ -n "${container_mount_paths:-}" ]; then
    echo "Container mount paths:"
    MOUNT_FLAGS=$(build_mount_flags "${container_runtime}" "${container_mount_paths}")
fi

# Read startup command
STARTUP_COMMAND="${startup_command:-}"
if [ -n "${STARTUP_COMMAND}" ]; then
    echo "Startup command: ${STARTUP_COMMAND}"
fi

# =============================================================================
# Enroot Runtime
# =============================================================================
if [[ "${container_runtime}" == "enroot" ]]; then
    echo "Using Enroot runtime..."

    # Read Enroot container path
    enroot_dir="${kasmvnc_enroot_dir:-/mnt/data/containers}"
    ENROOT_CONTAINER_PATH="${enroot_dir}/kasmvnc-${kasmvnc_os:-rocky9}.sqsh"

    # Verify .sqsh file exists
    if [ ! -f "${ENROOT_CONTAINER_PATH}" ]; then
        echo "ERROR: Enroot container not found at ${ENROOT_CONTAINER_PATH}" >&2
        exit 1
    fi
    echo "Using Enroot container: ${ENROOT_CONTAINER_PATH}"

    # Container instance name (includes OS to avoid stale cached instances)
    ENROOT_CONTAINER_NAME="kasmvnc-${kasmvnc_os:-rocky9}"

    # Create container instance if it doesn't exist (one-time per user per OS)
    if ! enroot list 2>/dev/null | grep -q "^${ENROOT_CONTAINER_NAME}$"; then
        echo "Creating Enroot container instance..."
        enroot create --name "${ENROOT_CONTAINER_NAME}" "${ENROOT_CONTAINER_PATH}"
    else
        echo "Enroot container instance already exists"
    fi

    # Create temp home for VNC files (overlay fs at /root doesn't support
    # colons in filenames, which VNC uses for hostname:display.pid/log)
    KASMVNC_HOME="/tmp/${USER}-kasmhome"
    mkdir -p "${KASMVNC_HOME}"

    # Build env flags from /etc/environment (host system variables)
    ENROOT_ENV_FLAGS=""
    if [ -f /etc/environment ]; then
        while IFS= read -r line || [ -n "${line}" ]; do
            line=$(echo "${line}" | xargs)
            [ -z "${line}" ] && continue
            [[ "${line}" == \#* ]] && continue
            ENROOT_ENV_FLAGS="${ENROOT_ENV_FLAGS} -e ${line}"
        done < /etc/environment
    fi

    # Start Enroot container (GPU support is enabled by default in Enroot)
    echo "Starting Enroot container..."
    enroot start --rw \
        ${MOUNT_FLAGS} \
        -m ${KASMVNC_HOME}:/root \
        ${ENROOT_ENV_FLAGS} \
        -e HOME=/root \
        -e BASE_PATH="${BASE_PATH}" \
        -e NGINX_PORT="${service_port}" \
        -e KASM_PORT="${kasm_port}" \
        -e VNC_DISPLAY="${vnc_display}" \
        -e STARTUP_COMMAND="${STARTUP_COMMAND}" \
        "${ENROOT_CONTAINER_NAME}" /usr/local/bin/run_kasm_nginx.sh &
    kasmvnc_container_pid=$!
    echo "Enroot container started with PID ${kasmvnc_container_pid}"

    # Add kill command to cancel.sh
    echo "kill ${kasmvnc_container_pid} 2>/dev/null || true" >> cancel.sh

# =============================================================================
# Singularity Runtime (default)
# =============================================================================
else
    echo "Using Singularity runtime..."

    # Determine container path
    if [ -n "${kasmvnc_container_path:-}" ]; then
        KASMVNC_CONTAINER_SIF="${kasmvnc_container_path}"
    else
        # Use cached container from controller setup
        sif_name="kasmvnc-${kasmvnc_os:-rocky9}.sif"
        KASMVNC_CONTAINER_SIF="${CONTAINER_DIR}/${sif_name}"
    fi

    # Verify container exists
    if [ ! -f "${KASMVNC_CONTAINER_SIF}" ]; then
        echo "ERROR: KasmVNC container not found at ${KASMVNC_CONTAINER_SIF}" >&2
        exit 1
    fi
    echo "Using container: ${KASMVNC_CONTAINER_SIF}"

    # Read GPU setting
    enable_gpu="${kasmvnc_enable_gpu:-true}"

    # GPU flag
    GPU_FLAG=""
    if [[ "${enable_gpu}" == "true" ]]; then
        GPU_FLAG="--nv"
        echo "GPU support enabled (--nv)"
    else
        echo "GPU support disabled"
    fi

    # Start Singularity container (--writable-tmpfs allows writes to /var/log/nginx etc.)
    echo "Starting Singularity container..."
    singularity run \
        --writable-tmpfs \
        ${GPU_FLAG} \
        ${MOUNT_FLAGS} \
        --env BASE_PATH="${BASE_PATH}" \
        --env NGINX_PORT="${service_port}" \
        --env KASM_PORT="${kasm_port}" \
        --env VNC_DISPLAY="${vnc_display}" \
        --env STARTUP_COMMAND="${STARTUP_COMMAND}" \
        --bind /etc/passwd:/etc/passwd:ro \
        --bind /etc/group:/etc/group:ro \
        --bind /etc/environment:/etc/environment:ro \
        "${KASMVNC_CONTAINER_SIF}" &
    kasmvnc_container_pid=$!
    echo "Singularity container started with PID ${kasmvnc_container_pid}"

    # Add kill command to cancel.sh
    echo "kill ${kasmvnc_container_pid} 2>/dev/null || true" >> cancel.sh
fi

# =============================================================================
# Wait for service to be ready
# =============================================================================
echo "=========================================="
echo "KasmVNC Container Desktop is RUNNING!"
echo "=========================================="
echo "Service port: ${service_port}"
echo "KasmVNC port: ${kasm_port}"
echo "VNC display: :${vnc_display}"
echo "BASE_PATH: ${BASE_PATH}"
echo "=========================================="

# Wait for container to exit
wait ${kasmvnc_container_pid}
