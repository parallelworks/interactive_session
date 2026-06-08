set -o pipefail
set -x

source tools/oras/libs.sh

if [ -n "${service_parent_install_dir}" ]; then
    container_dir=${service_parent_install_dir}/containers/kasmvnc-${kasmvnc_os}-gpu
    if ! [ -d "${container_dir}" ] && ! [ -w "${service_parent_install_dir}" ]; then
        echo "::warning::container_dir ${container_dir} does not exist and no write permission to ${service_parent_install_dir}. Resetting to ${HOME}/pw/software."
        service_parent_install_dir=${HOME}/pw/software
    fi
else
    service_parent_install_dir=${HOME}/pw/software
fi

mkdir -p ${service_parent_install_dir}/containers ${service_parent_install_dir}/tools
chmod a+rX ${service_parent_install_dir}/containers ${service_parent_install_dir}/tools

container_dir=${service_parent_install_dir}/containers/kasmvnc-${kasmvnc_os}-gpu       # GPU (VirtualGL) sandbox
container_tgz=${container_dir}.tgz
container_sif=${container_dir}.sif
base_container_dir=${service_parent_install_dir}/containers/kasmvnc-${kasmvnc_os}      # base sandbox (runs everywhere)
base_container_tgz=${base_container_dir}.tgz

# The controller runs on the controller/login node (which has internet) -- NOT on
# the compute node where the container ultimately runs. Its only job is to download
# the container(s); it must not install host packages or assume a local GPU.

# Download a sandbox tarball from ghcr and extract it in place (idempotent).
# Returns non-zero on failure (does NOT exit) so callers can fall back to another
# tier. The downloaded artifact keeps its own filename, landing at ${tgz}.
download_sandbox() {
    local repo=$1 dest=$2 tgz=$3
    [ -d "${dest}" ] && return 0
    echo "::group::Downloading ${repo}"
    rm -f "${tgz}"
    if ! ${PW_PARENT_JOB_DIR}/tools/oras/oras pull "${repo}" -o "$(dirname ${dest})"; then
        echo "::error title=Error::oras pull failed for ${repo}"; echo "::endgroup::"; return 1
    fi
    if [ ! -s "${tgz}" ]; then echo "::error title=Error::Failed to download ${tgz}"; echo "::endgroup::"; return 1; fi
    if ! tar -xzf "${tgz}" -C "$(dirname ${dest})"; then echo "::error title=Error::Failed to extract ${tgz}"; echo "::endgroup::"; return 1; fi
    rm -f "${tgz}"
    # Make the extracted sandbox fully readable/executable: tarballs carry root-owned,
    # restrictively-permissioned files; without this other users (and overlay setup)
    # can't read it and Python/Perl errors occur inside the container.
    chmod -R a+rX "${dest}"
    echo "::endgroup::"
}

# Default is software rendering: download only the base container and run it the
# old way. Hardware rendering provisions the GPU images. Singularity *sandbox
# directories* read unreliably from parallel/clustered filesystems (Lustre, WEKA,
# GPFS, NFS, ...) -- cold reads can return truncated data and corrupt Python/Perl
# files at startup -- so on those filesystems fetch all three images and let the
# start script fall back through them at run time (SIF if mountable -> GPU sandbox
# -> base). On local filesystems the GPU sandbox reads fine, so just fetch that.
if [ "${rendering}" != "hardware" ]; then
    echo "::notice::Software rendering selected; using base container only"
    download_sandbox ghcr.io/parallelworks/kasmvnc-${kasmvnc_os}:1.0 \
        "${base_container_dir}" "${base_container_tgz}" \
        || { echo "::error title=Error::Failed to provision base container"; exit 1; }
else
    fs_type=$(df -T "${service_parent_install_dir}/containers" 2>/dev/null | awk 'NR==2{print $2}')
    [ -z "${fs_type}" ] && fs_type=$(stat -f -c %T "${service_parent_install_dir}/containers" 2>/dev/null)
    echo "::notice::Hardware rendering selected; container filesystem type: ${fs_type:-unknown}"

    if echo "${fs_type}" | grep -qiE 'lustre|nfs|gpfs|weka|beegfs|panfs|fhgfs|ceph'; then
        # 1. Hardware-accelerated SIF (best-effort -- only usable where Singularity
        #    can mount a SIF unprivileged; the start script verifies that at run time).
        if [ ! -f "${container_sif}" ]; then
            echo "::group::KasmVNC GPU Container Download (SIF, ${fs_type} filesystem)"
            if ${PW_PARENT_JOB_DIR}/tools/oras/oras pull ghcr.io/parallelworks/kasmvnc-${kasmvnc_os}-sif:v1 \
                   -o "$(dirname ${container_sif})" && [ -s "${container_sif}" ]; then
                chmod a+rX "${container_sif}"
            else
                echo "::warning::SIF download unavailable; will rely on the sandbox images"
                rm -f "${container_sif}"
            fi
            echo "::endgroup::"
        fi
        # 2. GPU (VirtualGL) sandbox -- hardware accel where the SIF can't be mounted
        #    but the sandbox reads cleanly. Best-effort.
        download_sandbox ghcr.io/parallelworks/kasmvnc-${kasmvnc_os}-gpu:1.0 \
            "${container_dir}" "${container_tgz}" \
            || echo "::warning::GPU sandbox download failed; relying on SIF/base"
        # 3. Base sandbox -- the guaranteed fallback that runs on every system.
        download_sandbox ghcr.io/parallelworks/kasmvnc-${kasmvnc_os}:1.0 \
            "${base_container_dir}" "${base_container_tgz}" \
            || { echo "::error title=Error::Failed to provision base container"; exit 1; }
    else
        # Local filesystem -> GPU (VirtualGL) sandbox in place.
        download_sandbox ghcr.io/parallelworks/kasmvnc-${kasmvnc_os}-gpu:1.0 \
            "${container_dir}" "${container_tgz}" \
            || { echo "::error title=Error::Failed to provision GPU container"; exit 1; }
    fi
fi


xterm_path=$(which xterm 2>/dev/null)
if [ -z "${xterm_path}" ]; then
    sudo -n dnf install xterm -y 2>/dev/null || true
    xterm_path=$(which xterm 2>/dev/null)
fi
if [ -n "${xterm_path}" ] && [ ! -f "${service_parent_install_dir}/tools/xterm" ]; then
    cp ${xterm_path} ${service_parent_install_dir}/tools/xterm
    chmod a+x ${service_parent_install_dir}/tools/xterm
fi
