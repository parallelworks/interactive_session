#!/bin/bash
set -o pipefail

################################################################################
# Interactive Session Controller - KasmVNC Container Desktop
#
# Purpose: Download and prepare KasmVNC containerized desktop environment
# Runs on: Controller node with internet access
# Called by: Workflow preprocessing step
#
# Required Environment Variables:
#   - service_parent_install_dir: Install directory (default: ${HOME}/pw/software)
#   - kasmvnc_container_source: Source of container (bucket/git_lfs/path)
#   - kasmvnc_container_runtime: Container runtime (singularity/enroot)
################################################################################

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

CONTAINER_DIR="${HOME}/pw/singularity"

# =============================================================================
# Helper: Install Git LFS with fallback to direct binary download
# =============================================================================
install_git_lfs() {
    if git lfs version >/dev/null 2>&1; then
        echo "Git LFS already available: $(git lfs version)"
        return 0
    fi

    echo "Git LFS not found, installing..."

    # Try bootstrap from singularity-containers repo
    git clone --depth 1 https://github.com/parallelworks/singularity-containers.git \
        ~/singularity-containers-tmp 2>/dev/null || true
    if [ -d ~/singularity-containers-tmp ]; then
        bash ~/singularity-containers-tmp/scripts/sif_parts.sh install-lfs 2>/dev/null || true
        rm -rf ~/singularity-containers-tmp
    fi

    # Check if bootstrap worked
    if git lfs version >/dev/null 2>&1; then
        echo "Git LFS installed via bootstrap: $(git lfs version)"
        return 0
    fi

    # Fallback: download git-lfs binary directly
    echo "Bootstrap did not install git-lfs, downloading binary directly..."
    local lfs_version="3.5.1"
    local arch
    arch=$(uname -m)
    case "${arch}" in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
    esac
    local lfs_url="https://github.com/git-lfs/git-lfs/releases/download/v${lfs_version}/git-lfs-linux-${arch}-v${lfs_version}.tar.gz"
    local lfs_dir="${HOME}/.local/bin"
    mkdir -p "${lfs_dir}"

    if curl -sL "${lfs_url}" | tar xz -C /tmp/ 2>/dev/null; then
        cp "/tmp/git-lfs-${lfs_version}/git-lfs" "${lfs_dir}/"
        chmod +x "${lfs_dir}/git-lfs"
        export PATH="${lfs_dir}:${PATH}"
        rm -rf "/tmp/git-lfs-${lfs_version}"

        if git lfs version >/dev/null 2>&1; then
            echo "Git LFS installed directly: $(git lfs version)"
            return 0
        fi
    fi

    echo "WARNING: Failed to install Git LFS" >&2
    return 1
}

echo "=========================================="
echo "KasmVNC Container Setup (Controller Node)"
echo "=========================================="

# Determine container runtime (default to singularity)
container_runtime="${kasmvnc_container_runtime:-singularity}"
echo "Container runtime: ${container_runtime}"

# Handle Enroot runtime - no download needed, container is pre-deployed
if [[ "${container_runtime}" == "enroot" ]]; then
    enroot_dir="${kasmvnc_enroot_dir:-/mnt/data/containers}"
    enroot_path="${enroot_dir}/kasmvnc-${kasmvnc_os:-rocky9}.sqsh"
    echo "Using Enroot container: ${enroot_path}"
    echo "Enroot containers are pre-deployed, no download needed"

# Handle Singularity runtime with git_lfs source
elif [[ "${kasmvnc_container_source:-path}" == "git_lfs" ]]; then
    install_git_lfs

    # Derive git path and SIF name from OS choice
    git_path="kasmvnc-${kasmvnc_os:-rocky9}"
    sif_name="${git_path}.sif"

    # Pull KasmVNC container via sparse checkout + Git LFS
    KASMVNC_CONTAINER_SIF="${CONTAINER_DIR}/${sif_name}"
    if [ ! -f "${KASMVNC_CONTAINER_SIF}" ] || [ ! -s "${KASMVNC_CONTAINER_SIF}" ]; then
        echo "Fetching KasmVNC container via sparse checkout..."

        # Remove empty/corrupt file if it exists
        rm -f "${KASMVNC_CONTAINER_SIF}" 2>/dev/null || true

        # Pull to tmp location first
        TMP_CONTAINER_DIR="$(mktemp -d)/singularity-containers"
        mkdir -p "${TMP_CONTAINER_DIR}"

        cd "${TMP_CONTAINER_DIR}"
        git init
        git_repo="${kasmvnc_git_repo:-https://github.com/parallelworks/singularity-containers.git}"
        git_branch="${kasmvnc_git_branch:-main}"
        git remote add origin "${git_repo}"
        git config core.sparseCheckout true
        echo "${git_path}/*" > .git/info/sparse-checkout
        git lfs install
        git pull origin "${git_branch}"
        # Explicitly fetch LFS files
        git lfs pull --include="${git_path}/*"

        # Join SIF parts if split, otherwise just copy
        mkdir -p "${CONTAINER_DIR}"

        # Check if there are split parts (e.g., kasmvnc-rocky9.sif.00, .01, etc.)
        if compgen -G "${git_path}/${sif_name}.*" > /dev/null 2>&1; then
            echo "Joining SIF parts..."
            cat ${git_path}/${sif_name}.* > "${KASMVNC_CONTAINER_SIF}"
        elif [ -f "${git_path}/${sif_name}" ]; then
            echo "Copying KasmVNC container..."
            cp "${git_path}/${sif_name}" "${KASMVNC_CONTAINER_SIF}"
        else
            echo "WARNING: KasmVNC container not found after pull" >&2
        fi

        cd - >/dev/null
        rm -rf "${TMP_CONTAINER_DIR}"

        echo "KasmVNC container cached at ${KASMVNC_CONTAINER_SIF}"
    else
        echo "KasmVNC container already present at ${KASMVNC_CONTAINER_SIF}"
    fi

# Handle Singularity runtime with bucket source
elif [[ "${kasmvnc_container_source:-path}" == "bucket" ]]; then
    # Pull from PW bucket
    bucket_uri="${kasmvnc_bucket_uri}"
    if [ -z "${bucket_uri}" ]; then
        echo "ERROR: kasmvnc_bucket_uri not provided" >&2
        exit 1
    fi

    # Derive cache filename from OS choice (avoids overwriting when switching OS)
    bucket_sif_name="kasmvnc-${kasmvnc_os:-rocky9}.sif"
    KASMVNC_CONTAINER_SIF="${CONTAINER_DIR}/${bucket_sif_name}"
    mkdir -p "${CONTAINER_DIR}"

    if [ ! -f "${KASMVNC_CONTAINER_SIF}" ] || [ ! -s "${KASMVNC_CONTAINER_SIF}" ]; then
        echo "Pulling KasmVNC container from bucket: ${bucket_uri}"
        rm -f "${KASMVNC_CONTAINER_SIF}" 2>/dev/null || true
        pw bucket cp "${bucket_uri}" "${KASMVNC_CONTAINER_SIF}"
        echo "KasmVNC container cached at ${KASMVNC_CONTAINER_SIF}"
    else
        echo "KasmVNC container already present at ${KASMVNC_CONTAINER_SIF}"
    fi

else
    # User-provided path - no download needed
    container_path="${kasmvnc_container_path}"
    if [ -z "${container_path}" ]; then
        echo "ERROR: kasmvnc_container_path not provided" >&2
        exit 1
    fi
    echo "Using user-provided container path: ${container_path}"
fi

echo "=========================================="
echo "Setup complete!"
echo "=========================================="
