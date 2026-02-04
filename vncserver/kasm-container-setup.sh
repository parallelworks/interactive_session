#!/bin/bash
# setup.sh - Desktop Setup Script (runs on controller node)
#
# This script runs on the controller/login node in STEP 1 of the session_runner job.
# It runs BEFORE start.sh is submitted to the compute node.
#
# Use it to:
# - Download noVNC from GitHub (compute nodes often lack internet) [native mode]
# - Install Git LFS if needed
# - Pull nginx container via Git LFS [native mode]
# - Pull KasmVNC container via Git LFS [KasmVNC container mode]
# - Generate VNC password and build connection slug [native mode]
#
# Coordinate files written here:
#   - KASMVNC_CONTAINER_PATH - Path to KasmVNC container [KasmVNC container mode]

set -e

echo "=========================================="
echo "Desktop Setup (Controller Node)"
echo "=========================================="

# =============================================================================
# Configuration
# =============================================================================
# Normalize job directory path (remove trailing slash if present)
JOB_DIR="${PW_PARENT_JOB_DIR%/}"

CONTAINER_DIR="${HOME}/pw/singularity"
SOFTWARE_DIR="${HOME}/pw/software"
mkdir -p ${SOFTWARE_DIR}


# =============================================================================
# KasmVNC Container Mode
# =============================================================================
echo "KasmVNC Container mode: skipping noVNC and nginx downloads"
# Ensure Git LFS is available (needed for git_lfs source)
if [[ "${desktop_kasmvnc_container_source:-path}" == "git_lfs" ]]; then
    if ! git lfs version >/dev/null 2>&1; then
        echo "Git LFS not found, installing..."
        git clone --depth 1 https://github.com/parallelworks/singularity-containers.git \
            ~/singularity-containers-tmp || true

        if [ -d ~/singularity-containers-tmp ]; then
            bash ~/singularity-containers-tmp/scripts/sif_parts.sh install-lfs
            rm -rf ~/singularity-containers-tmp
            echo "Git LFS installed successfully"
        else
            echo "WARNING: Failed to install Git LFS" >&2
        fi
    else
        echo "Git LFS already available: $(git lfs version)"
    fi

    # Pull KasmVNC container via sparse checkout + Git LFS
    KASMVNC_CONTAINER_SIF="${CONTAINER_DIR}/kasmvnc.sif"
    if [ ! -f "${KASMVNC_CONTAINER_SIF}" ] || [ ! -s "${KASMVNC_CONTAINER_SIF}" ]; then
        echo "Fetching KasmVNC container via sparse checkout..."

        # Remove empty/corrupt file if it exists
        rm -f "${KASMVNC_CONTAINER_SIF}" 2>/dev/null || true

        # Pull to tmp location first
        TMP_CONTAINER_DIR="$(mktemp -d)/singularity-containers"
        mkdir -p "${TMP_CONTAINER_DIR}"

        cd "${TMP_CONTAINER_DIR}"
        git init
        git_repo="${desktop_kasmvnc_git_repo:-https://github.com/parallelworks/singularity-containers.git}"
        git_path="${desktop_kasmvnc_git_path:-kasmvnc}"
        git_branch="${desktop_kasmvnc_git_branch:-main}"
        git remote add origin "${git_repo}"
        git config core.sparseCheckout true
        echo "${git_path}/*" > .git/info/sparse-checkout
        git lfs install
        git pull origin "${git_branch}"
        # Explicitly fetch LFS files
        git lfs pull --include="${git_path}/*"

        # Join SIF parts if split, otherwise just copy
        mkdir -p "${CONTAINER_DIR}"

        # Check if there are split parts (kasmvnc.sif.00, kasmvnc.sif.01, etc.)
        if compgen -G "${git_path}/kasmvnc.sif.*" > /dev/null 2>&1; then
            echo "Joining SIF parts..."
            cat ${git_path}/kasmvnc.sif.* > "${CONTAINER_DIR}/kasmvnc.sif"
        elif [ -f "${git_path}/kasmvnc.sif" ]; then
            echo "Copying KasmVNC container..."
            cp "${git_path}/kasmvnc.sif" "${CONTAINER_DIR}/kasmvnc.sif"
        else
            echo "WARNING: KasmVNC container not found after pull" >&2
        fi

        cd - >/dev/null
        rm -rf "${TMP_CONTAINER_DIR}"

        echo "KasmVNC container cached at ${KASMVNC_CONTAINER_SIF}"
    else
        echo "KasmVNC container already present at ${KASMVNC_CONTAINER_SIF}"
    fi

    echo "${KASMVNC_CONTAINER_SIF}" > "${JOB_DIR}/KASMVNC_CONTAINER_PATH"

elif [[ "${desktop_kasmvnc_container_source:-path}" == "bucket" ]]; then
    # Pull from PW bucket (KASM_BUCKET_URI includes full path)
    bucket_uri="${KASM_BUCKET_URI}"
    if [ -z "${bucket_uri}" ]; then
        echo "ERROR: kasmvnc_bucket not provided" >&2
        exit 1
    fi

    KASMVNC_CONTAINER_SIF="${CONTAINER_DIR}/kasmvnc.sif"
    mkdir -p "${CONTAINER_DIR}"

    if [ ! -f "${KASMVNC_CONTAINER_SIF}" ] || [ ! -s "${KASMVNC_CONTAINER_SIF}" ]; then
        echo "Pulling KasmVNC container from bucket: ${bucket_uri}"
        rm -f "${KASMVNC_CONTAINER_SIF}" 2>/dev/null || true
        pw bucket cp "${bucket_uri}" "${KASMVNC_CONTAINER_SIF}"
        echo "KasmVNC container cached at ${KASMVNC_CONTAINER_SIF}"
    else
        echo "KasmVNC container already present at ${KASMVNC_CONTAINER_SIF}"
    fi

    echo "${KASMVNC_CONTAINER_SIF}" > "${JOB_DIR}/KASMVNC_CONTAINER_PATH"

else
    # User-provided path
    container_path="${desktop_kasmvnc_container_path}"
    if [ -z "${container_path}" ]; then
        echo "ERROR: kasmvnc_container_path not provided" >&2
        exit 1
    fi
    echo "Using user-provided container path: ${container_path}"
    echo "${container_path}" > "${JOB_DIR}/KASMVNC_CONTAINER_PATH"
fi

# Write GPU setting for start.sh
echo "${desktop_kasmvnc_enable_gpu:-true}" > "${JOB_DIR}/KASMVNC_CONTAINER_ENABLE_GPU"


# Use xterm to access the host directly
xterm_path=$(which xterm)
if ! [ -z ${xterm_path} ]; then
    cp ${xterm_path} ${SOFTWARE_DIR}/xterm
    chmod +x ${SOFTWARE_DIR}/xterm
fi