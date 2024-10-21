mkdir -p ~/pw/software

# Load or install mlflow
if [ -z "${service_load_env}" ]; then
    pip3 install mlflow
else
    eval ${service_load_env}
fi

eval ${service_mlflow_server_command}
