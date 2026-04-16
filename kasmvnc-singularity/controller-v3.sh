set -o pipefail
set -x


if [ -n "${service_parent_install_dir}" ]; then
    container_dir=${service_parent_install_dir}/containers/kasmvnc-${kasmvnc_os}
    if ! [ -d "${container_dir}" ] && ! [ -w "${service_parent_install_dir}" ]; then
        echo "::warning::container_dir ${container_dir} does not exist and no write permission to ${service_parent_install_dir}. Resetting to ${HOME}/pw/software."
        service_parent_install_dir=${HOME}/pw/software
    fi
else
    service_parent_install_dir=${HOME}/pw/software
fi
# FIXME: REMOVE THE NEXT LINE. It's only here to clean leftovers form previous versions of this workflow
rm -rf ${service_parent_install_dir}/kasmvnc-${kasmvnc_os} ${service_parent_install_dir}/oras ${service_parent_install_dir}/xterm
mkdir -p ${service_parent_install_dir}/containers ${service_parent_install_dir}/tools
chmod a+rX ${service_parent_install_dir}/containers ${service_parent_install_dir}/tools

container_dir=${service_parent_install_dir}/containers/kasmvnc-${kasmvnc_os}
container_tgz=${container_dir}.tgz

download_oras(){
    if [ -d "${service_parent_install_dir}/tools/oras/oras" ]; then
        return
    fi
    VER="1.2.0"   # example — replace with newest
    wget https://github.com/oras-project/oras/releases/download/v${VER}/oras_${VER}_linux_amd64.tar.gz
    mkdir -p ${service_parent_install_dir}/tools/oras
    tar -xvf oras_${VER}_linux_amd64.tar.gz -C ${service_parent_install_dir}/tools/oras
    chmod -R a+rX ${service_parent_install_dir}/tools/oras
    rm oras_${VER}_linux_amd64.tar.gz
}

oras_pull_file(){
    repo=$1
    repo_path=$2
    host_path=$3
    ${service_parent_install_dir}/tools/oras/oras pull ${repo}
    mv ${repo_path} ${host_path}
}


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
    chmod -R a+rX ${container_dir}
    echo "::endgroup::"
fi


xterm_path=$(which xterm 2>/dev/null)
if [ -z "${xterm_path}" ]; then
    sudo -n dnf install xterm -y 2>/dev/null || true
    xterm_path=$(which xterm 2>/dev/null)
fi
if [ -n "${xterm_path}" ]; then
    cp ${xterm_path} ${service_parent_install_dir}/tools/xterm
    chmod a+x ${service_parent_install_dir}/tools/xterm
fi
