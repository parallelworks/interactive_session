set -o pipefail
set -x

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

mkdir -p ${service_parent_install_dir}

xterm_path=$(which xterm)
if ! [ -z ${xterm_path} ]; then
    cp ${xterm_path} ${service_parent_install_dir}/xterm
    chmod +x ${service_parent_install_dir}/xterm
fi

