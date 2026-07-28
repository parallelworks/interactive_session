set -o pipefail
set -x

source tools/oras/libs.sh

if [ -n "${service_parent_install_dir}" ]; then
    container_sif=${service_parent_install_dir}/containers/kasmvnc-${kasmvnc_os}-gpu.sif
    if ! [ -f "${container_sif}" ] && ! [ -w "${service_parent_install_dir}" ]; then
        echo "::warning::container_sif ${container_sif} does not exist and no write permission to ${service_parent_install_dir}. Resetting to ${HOME}/pw/software."
        service_parent_install_dir=${HOME}/pw/software
    fi
else
    service_parent_install_dir=${HOME}/pw/software
fi

mkdir -p ${service_parent_install_dir}/containers ${service_parent_install_dir}/tools
chmod a+rX ${service_parent_install_dir}/containers ${service_parent_install_dir}/tools

container_sif=${service_parent_install_dir}/containers/kasmvnc-${kasmvnc_os}-gpu.sif

# The controller runs on the controller/login node (which has internet) -- NOT on
# the compute node where the container ultimately runs. Its only job is to download
# the SIF; whether the node can mount it (and whether a sandbox must be built from
# it) is decided at run time by start-template-v4.sh.
sif_repo=ghcr.io/parallelworks/kasmvnc-${kasmvnc_os}-sif:v1

# A truncated SIF (e.g. left by an interrupted download before pulls were
# atomic) fails every downstream mount and sandbox build with squashfs EOF
# errors, so never trust an existing file blindly: compare its size against
# the registry manifest and re-download on mismatch. Skipped when the manifest
# fetch fails, so an offline controller keeps working with the existing file.
if [ -f "${container_sif}" ]; then
    expected_size=$(oras_expected_size ${sif_repo})
    actual_size=$(stat -c%s "${container_sif}" 2>/dev/null || echo 0)
    if [ -n "${expected_size}" ] && [ "${actual_size}" != "${expected_size}" ]; then
        echo "::warning::${container_sif} is ${actual_size} bytes but the registry manifest says ${expected_size}; re-downloading"
        rm -f "${container_sif}"
    fi
fi

if ! [ -f "${container_sif}" ]; then
    echo "::group::KasmVNC SIF Download"
    echo "::notice::Using GitHub registry to download file"
    oras_pull_file ${sif_repo} kasmvnc-${kasmvnc_os}-gpu.sif ${container_sif}
    if [ ! -s ${container_sif} ]; then
        echo "::error title=Error::Failed to download file ${container_sif}"
        exit 1
    fi
    chmod a+r ${container_sif}
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
