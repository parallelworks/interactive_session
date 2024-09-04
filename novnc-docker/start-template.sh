echo "$(date): $(hostname):${PWD} $0 $@"

if [[ ${service_use_gpus} == "true" ]]; then
    gpu_flag="--gpus all"
else
    gpu_flag=""
fi

if [[ ${jobschedulertype} == "CONTROLLER" ]]; then
    echo sudo -n docker stop jupyter-$service_port > docker-kill-${job_number}.sh
else
    # Create kill script. Needs to be here because we need the hostname of the compute node.
    echo ssh "'$(hostname)'" sudo -n docker stop jupyter-$service_port > docker-kill-${job_number}.sh
fi

# Create kill script. Needs to be here because we need the hostname of the compute node.
echo ssh "'$(hostname)'" sudo -n docker stop jupyter-$service_port > docker-kill-${job_number}.sh
chmod 777 docker-kill-${job_number}.sh

sudo -n systemctl start docker

# Docker supports mounting directories that do not exist (singularity does not)

set -x
sudo -n docker run ${gpu_flag} --rm \
    -v /contrib:/contrib -v /lustre:/lustre -v ${HOME}:${HOME} \
    --name=novnc-$service_port -p $service_port:6901 ${service_docker_repo}
