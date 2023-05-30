echo "$(date): $(hostname):${PWD} $0 $@"

job_number=__job_number__
partition_or_controller=__partition_or_controller__

if [[ ${use_gpus} == "true" ]]; then
    gpu_flag="--gpus all"
else
    gpu_flag=""
fi

if [[ ${host_jobschedulertype} == "CONTROLLER" ]]; then
    echo sudo -n docker stop jupyter-$servicePort > docker-kill-${job_number}.sh
else
    # Create kill script. Needs to be here because we need the hostname of the compute node.
    echo ssh "'$(hostname)'" sudo -n docker stop jupyter-$servicePort > docker-kill-${job_number}.sh
fi

# Create kill script. Needs to be here because we need the hostname of the compute node.
echo ssh "'$(hostname)'" sudo -n docker stop jupyter-$servicePort > docker-kill-${job_number}.sh
chmod 777 docker-kill-${job_number}.sh

sudo -n systemctl start docker

# Docker supports mounting directories that do not exist (singularity does not)

set -x
sudo -n docker run ${gpu_flag} --rm \
    -v /contrib:/contrib -v /lustre:/lustre -v ${HOME}:${HOME} \
    --name=novnc-$servicePort -p $servicePort:6901 __docker_repo__
