cd ${resource_jobdir}

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

if [ -z "${service_nginx_sif}" ]; then
    service_nginx_sif=${service_parent_install_dir}/open-webui.sif
fi

if ! [ -f ${service_nginx_sif} ]; then
    echo; echo
    echo "Singularity container ${service_nginx_sif} not found"
    echo "Creating container"
    module load singularity
    singularity pull ${service_nginx_sif} docker://ghcr.io/open-webui/open-webui:main
fi

