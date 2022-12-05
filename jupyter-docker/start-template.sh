echo "$(date): $(hostname):${PWD} $0 $@"

job_number=__job_number__
partition_or_controller=__partition_or_controller__

if [[ __use_gpus__ == "True" ]]; then
    gpu_flag="--gpus all"
else
    gpu_flag=""
fi

if [[ ${partition_or_controller} == "True" ]]; then
    # Create kill script. Needs to be here because we need the hostname of the compute node.
    echo ssh "'$(hostname)'" sudo -n docker stop jupyter-$servicePort > docker-kill-${job_number}.sh
else
    echo sudo -n docker stop jupyter-$servicePort > docker-kill-${job_number}.sh
fi

chmod 777 docker-kill-${job_number}.sh

sudo -n systemctl start docker


# Generate sha:
if [ -z "${password}" ] || [[ "${password}" == "__""password""__" ]]; then
    echo "No password was specified"
    sha=""
else
    echo "Generating sha"
    sha=$(sudo -n docker run --rm __docker_repo__ python3 -c "from notebook.auth.security import passwd; print(passwd('__password__', algorithm = 'sha1'))")
fi

if [[ "$NEW_USERCONTAINER" == "0" ]];then
    tornado_settings="{'static_url_prefix':'/me/${openPort}/static/'}"
    base_url="/me/${openPort}/"
else
    tornado_settings="{'static_url_prefix':'/${FORWARDPATH}/${IPADDRESS}/${openPort}/static/'}"
    base_url="/${FORWARDPATH}/${IPADDRESS}/${openPort}/"
fi

# Docker supports mounting directories that do not exist (singularity does not)
set -x
sudo -n docker run ${gpu_flag} --rm \
    -v /contrib:/contrib -v /lustre:/lustre -v ${HOME}:${HOME} \
    --name=jupyter-$servicePort \
    -p $servicePort:$servicePort \
    __docker_repo__ jupyter-notebook \
    --port=$servicePort \
    --ip=0.0.0.0 \
    --NotebookApp.iopub_data_rate_limit=10000000000 \
    --NotebookApp.token= \
    --NotebookApp.password=${sha} \
    --no-browser \
    --allow-root \
    --notebook-dir=/ \
    --NotebookApp.tornado_settings="${tornado_settings}" \
    --NotebookApp.base_url="${base_url}" \
    --NotebookApp.allow_origin=*