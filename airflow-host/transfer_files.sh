
rsync  -e "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" -avzq ${pw_job_dir}/${service_name}/dags ${resource_publicIp}:${resource_jobdir}

