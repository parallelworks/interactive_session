set -e

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${resource_workdir}/pw/software
fi

rsync  -e "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" -avzq --rsync-path="mkdir -p ${service_parent_install_dir} && rsync" ${pw_job_dir}/${service_name}/slurm-wrapper-app-v3.py ${resource_publicIp}:${resource_jobdir}
rsync  -e "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" -avzq --rsync-path="mkdir -p ${service_parent_install_dir} && rsync" ${pw_job_dir}/${service_name}/run_callback.sh ${resource_publicIp}:${resource_jobdir}
rsync  -e "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" -avzq --rsync-path="mkdir -p ${service_parent_install_dir} && rsync" ${pw_job_dir}/${service_name}/run_pending_callbacks.sh ${resource_publicIp}:${resource_jobdir}
