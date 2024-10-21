mkdir -p ~/pw/software

# Load or install mlflow
if [ -z "${service_load_env}" ]; then
    pip3 install mlflow
else
    eval ${service_load_env}
fi

${sshusercontainer} "${pw_job_dir}/utils/notify.sh Running"

eval ${service_mlflow_server_command}
