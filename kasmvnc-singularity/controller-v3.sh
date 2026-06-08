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

container_dir=${service_parent_install_dir}/containers/kasmvnc-${kasmvnc_os}-gpu
container_tgz=${container_dir}.tgz
container_sif=${container_dir}.sif

# The controller runs on the controller/login node (which has internet) -- NOT on
# the compute node where the container ultimately runs. Its only job here is to
# download the container; it must not install host packages or assume a GPU is
# present locally. We always fetch the GPU (VirtualGL) container: it auto-detects
# at session start and falls back to software rendering when no GPU is available.
#
# Singularity *sandbox directories* read unreliably from parallel/clustered
# filesystems (Lustre, WEKA, GPFS, NFS, ...): cold reads can return truncated
# data and corrupt Python/Perl files at startup. On those filesystems download a
# single-file SIF image (reads reliably); on local filesystems use the sandbox.
fs_type=$(df -T "${service_parent_install_dir}/containers" 2>/dev/null | awk 'NR==2{print $2}')
[ -z "${fs_type}" ] && fs_type=$(stat -f -c %T "${service_parent_install_dir}/containers" 2>/dev/null)
echo "::notice::Container filesystem type: ${fs_type:-unknown}"

if echo "${fs_type}" | grep -qiE 'lustre|nfs|gpfs|weka|beegfs|panfs|fhgfs|ceph'; then
    # Parallel/clustered filesystem -> use a SIF image.
    if [ ! -f "${container_sif}" ]; then
        echo "::group::KasmVNC GPU Container Download (SIF, ${fs_type} filesystem)"
        echo "::notice::Using GitHub registry to download SIF"
        oras_pull_file ghcr.io/parallelworks/kasmvnc-${kasmvnc_os}-sif:v1 kasmvnc-${kasmvnc_os}-gpu.sif ${container_sif}
        if [ ! -s ${container_sif} ]; then
            echo "::error title=Error::Failed to download file ${container_sif}"
            exit 1
        fi
        chmod a+rX ${container_sif}
        echo "::endgroup::"
    fi
elif ! [ -d "${container_dir}" ]; then
    # Local filesystem -> use the sandbox directory (tarball + extract).
    echo "::group::KasmVNC GPU Container Download (sandbox)"
    echo "::notice::Using GitHub registry to download file"
    oras_pull_file ghcr.io/parallelworks/kasmvnc-${kasmvnc_os}-gpu:1.0 kasmvnc-${kasmvnc_os}-gpu.tgz ${container_tgz}
    if [ ! -s ${container_tgz} ]; then
        echo "::error title=Error::Failed to download file ${container_tgz}"
        exit 1
    fi
    if ! tar -xzf ${container_tgz} -C $(dirname ${container_dir}); then
        echo "::error title=Error::Failed to extract ${container_tgz}"
        exit 1
    fi
    rm ${container_tgz}
    # Ensure the extracted sandbox is fully readable/executable by the current user.
    # Singularity sandbox tarballs often contain root-owned files with restrictive
    # permissions; without this, --writable-tmpfs overlayfs setup fails on the first
    # run, causing Python/Perl errors inside the container.
    chmod -R a+rX ${container_dir}
    echo "::endgroup::"
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
