echo "$(date): $(hostname):${PWD} $0 $@"

servicePort=__servicePort__
job_number=__job_number__

if [[ ${use_gpus} == "True" ]]; then
    gpu_flag="--gpus all"
else
    gpu_flag=""
fi

# Create kill script. Needs to be here because we need the hostname of the compute node.
echo ssh "'$(hostname)'" sudo docker stop jupyter-$servicePort > docker-kill-${job_number}.sh
chmod 777 docker-kill-${job_number}.sh

sudo systemctl start docker

sudo docker run ${gpu_flag} --rm --name=jupyter-$servicePort -p $servicePort:$servicePort __docker_repo__ /opt/conda/bin/jupyter-notebook \
    --port=$servicePort \
    --ip=0.0.0.0 \
    --NotebookApp.iopub_data_rate_limit=10000000000 \
    --NotebookApp.token= \
    --NotebookApp.password= \
    --no-browser \
    --notebook-dir=/ \
    --NotebookApp.tornado_settings="{'static_url_prefix':'/${FORWARDPATH}/${IPADDRESS}/${openPort}/static/'}" \
    --NotebookApp.base_url="/${FORWARDPATH}/${IPADDRESS}/${openPort}/" \
    --NotebookApp.allow_origin=*