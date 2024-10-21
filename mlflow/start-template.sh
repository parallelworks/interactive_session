
# Load or install mlflow
if [ -z "${service_load_env}" ]; then
    export PATH=${PATH}:~/.local/bin
    eval ${service_mlflow_install_cmd}
else
    eval ${service_mlflow_load_cmd}
fi

${sshusercontainer} "${pw_job_dir}/utils/notify.sh Running"

mlflow server --port ${service_port} ${additional_flags}
