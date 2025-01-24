
if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${resource_workdir}/pw/software
fi

rsync  -e "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" -avzq --rsync-path="mkdir -p ${service_parent_install_dir} && rsync" ${pw_job_dir}/${service_name}/*.yaml ${resource_publicIp}:${resource_jobdir}

