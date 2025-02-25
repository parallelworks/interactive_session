cd ${resource_jobdir}

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

service_install_dir=${service_parent_install_dir}/JuiceServer

if ! [ -f ${service_install_dir}/agent ]; then
   rm -rf ${service_install_dir}
    wget ${service_download_url}
    mkdir -p ${service_install_dir}
    tar -xf JuiceServer-linux.tar.gz -C ${service_install_dir}
    ${service_install_dir}/agent --help
fi
