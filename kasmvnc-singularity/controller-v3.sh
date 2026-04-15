set -o pipefail
set -x

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

container_tgz=${service_parent_install_dir}/kasmvnc-${kasmvnc_os}.tgz
container_dir=${service_parent_install_dir}/kasmvnc-${kasmvnc_os}

download_oras(){
    VER="1.2.0"   # example — replace with newest                                                                                    
    wget https://github.com/oras-project/oras/releases/download/v${VER}/oras_${VER}_linux_amd64.tar.gz
    mkdir -p ${service_parent_install_dir}/oras
    tar -xvf oras_${VER}_linux_amd64.tar.gz -C ${service_parent_install_dir}/oras
    rm oras_${VER}_linux_amd64.tar.gz
}

oras_pull_file(){
    repo=$1
    repo_path=$2
    host_path=$3
    ${service_parent_install_dir}/oras/oras pull ${repo}
    mv ${repo_path} ${host_path}
}

mkdir -p ${service_parent_install_dir}

# The reason we need service_download_vncserver_container is:
# - vncserver can be installed in the compute nodes but not in the controlle nodes
# - Some compute nodes don't have access to the internet
if ! [ -d "${container_dir}" ]; then
    echo "::group::KasmVNC Container Download"
    echo "::notice::Using GitHub registry to download file"
    download_oras
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
    chmod -R u+rwX ${container_dir}
    echo "::endgroup::"
fi


xterm_path=$(which xterm 2>/dev/null)
if [ -z "${xterm_path}" ]; then
    sudo -n dnf install xterm -y 2>/dev/null || true
    xterm_path=$(which xterm 2>/dev/null)
fi
if [ -n "${xterm_path}" ]; then
    cp ${xterm_path} ${service_parent_install_dir}/xterm
    chmod +x ${service_parent_install_dir}/xterm
fi
