
rsync -avzq --rsync-path="mkdir -p ${service_parent_install_dir} && rsync" ${pw_job_dir}/${service_name}/slurm-wrapper-app.py ${resource_publicIp}:${resource_jobdir}