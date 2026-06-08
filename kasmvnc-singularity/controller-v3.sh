set -o pipefail
set -x

source tools/oras/libs.sh

if [ -n "${service_parent_install_dir}" ]; then
    container_dir=${service_parent_install_dir}/containers/kasmvnc-${kasmvnc_os}
    if ! [ -d "${container_dir}" ] && ! [ -w "${service_parent_install_dir}" ]; then
        echo "::warning::container_dir ${container_dir} does not exist and no write permission to ${service_parent_install_dir}. Resetting to ${HOME}/pw/software."
        service_parent_install_dir=${HOME}/pw/software
    fi
else
    service_parent_install_dir=${HOME}/pw/software
fi

mkdir -p ${service_parent_install_dir}/containers ${service_parent_install_dir}/tools
chmod a+rX ${service_parent_install_dir}/containers ${service_parent_install_dir}/tools

container_dir=${service_parent_install_dir}/containers/kasmvnc-${kasmvnc_os}
container_tgz=${container_dir}.tgz

# The reason we need service_download_vncserver_container is:
# - vncserver can be installed in the compute nodes but not in the controlle nodes
# - Some compute nodes don't have access to the internet
if ! [ -d "${container_dir}" ]; then
    echo "::group::KasmVNC Container Download"
    echo "::notice::Using GitHub registry to download file"
    oras_pull_file ghcr.io/parallelworks/kasmvnc-${kasmvnc_os}:1.0 kasmvnc-${kasmvnc_os}.tgz ${container_tgz}
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

# --- Hardware-acceleration provisioning (best-effort, GPU nodes only) ----------
# Locate this runtime's helper scripts (co-located with this controller script).
kasm_src_dir=""
for _d in "${PW_PARENT_JOB_DIR}/kasmvnc-singularity" "$(pwd)/kasmvnc-singularity" "$(pwd)"; do
    if [ -n "${_d}" ] && [ -f "${_d}/build-gpu-container.sh" ]; then
        kasm_src_dir="${_d}"
        break
    fi
done

if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
    echo "::group::GPU detected - provisioning hardware-accelerated (VirtualGL) desktop"

    # Ensure the host has NVIDIA OpenGL/EGL userspace so Singularity --nv can
    # inject it into the container (compute-only driver images lack it).
    if [ -n "${kasm_src_dir}" ] && [ -f "${kasm_src_dir}/install-host-nvidia-gl.sh" ]; then
        bash "${kasm_src_dir}/install-host-nvidia-gl.sh" || echo "::warning::host NVIDIA GL setup skipped/failed"
    fi

    # Obtain the VirtualGL-enabled container. Prefer the prebuilt package from the
    # registry (same mechanism as the base image above); fall back to building it
    # locally from the base image if the pull is unavailable. Idempotent.
    gpu_container_dir="${container_dir}-gpu"
    gpu_container_tgz="${gpu_container_dir}.tgz"
    if [ ! -d "${gpu_container_dir}" ]; then
        echo "::notice::Pulling GPU container ghcr.io/parallelworks/kasmvnc-${kasmvnc_os}-gpu:1.0"
        rm -f "${gpu_container_tgz}"
        if ${PW_PARENT_JOB_DIR}/tools/oras/oras pull ghcr.io/parallelworks/kasmvnc-${kasmvnc_os}-gpu:1.0 -o "$(dirname ${gpu_container_dir})" \
           && [ -s "${gpu_container_tgz}" ] \
           && tar -xzf "${gpu_container_tgz}" -C "$(dirname ${gpu_container_dir})"; then
            rm -f "${gpu_container_tgz}"
            chmod -R a+rX "${gpu_container_dir}" 2>/dev/null || true
            echo "::notice::GPU container ready (pulled): ${gpu_container_dir}"
        else
            echo "::warning::GPU container pull failed; building locally from base image"
            rm -f "${gpu_container_tgz}"
            if [ -n "${kasm_src_dir}" ] && [ -f "${kasm_src_dir}/build-gpu-container.sh" ] \
               && [ -d "${container_dir}" ]; then
                bash "${kasm_src_dir}/build-gpu-container.sh" "${container_dir}" "${gpu_container_dir}" \
                    || echo "::warning::GPU container build failed; desktop will use software rendering"
            fi
        fi
    fi
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
