set -o pipefail
set -x

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

mkdir -p ${service_parent_install_dir}

xterm_path=$(which xterm 2>/dev/null)
if [ -z "${xterm_path}" ]; then
    sudo -n dnf install xterm -y 2>/dev/null || true
    xterm_path=$(which xterm 2>/dev/null)
fi
if [ -n "${xterm_path}" ]; then
    cp ${xterm_path} ${service_parent_install_dir}/xterm
    chmod +x ${service_parent_install_dir}/xterm
fi

