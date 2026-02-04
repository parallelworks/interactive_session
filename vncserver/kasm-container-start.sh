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
cleanup_kasmvnc_container() {
    echo "$(date) Stopping KasmVNC container..."
    if [ -n "${kasmvnc_container_pid:-}" ]; then
        kill ${kasmvnc_container_pid} 2>/dev/null || true
    fi
}
trap cleanup_kasmvnc_container EXIT INT TERM

# Start KasmVNC container
echo "Starting Singularity container..."
singularity run \
    ${GPU_FLAG} \
    --env BASE_PATH="${basepath}" \
    --env NGINX_PORT="${service_port}" \
    --env KASM_PORT=8590 \
    --bind /etc/passwd:/etc/passwd:ro \
    --bind /etc/group:/etc/group:ro \
    "${KASMVNC_CONTAINER_SIF}" &

kasmvnc_container_pid=$!
echo "KasmVNC container started with PID ${kasmvnc_container_pid}"

sleep 6  # Allow container to start

# Wait for container to exit
wait ${kasmvnc_container_pid}

