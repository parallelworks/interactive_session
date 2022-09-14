echo "$(date): $(hostname):${PWD} $0 $@"

servicePort=__servicePort__
job_number=__job_number__
partition_or_controller=__partition_or_controller__

if [[ ${use_gpus} == "True" ]]; then
    gpu_flag="--gpus all"
else
    gpu_flag=""
fi

if [[ ${partition_or_controller} == "True" ]]; then
    # Create kill script. Needs to be here because we need the hostname of the compute node.
    echo ssh "'$(hostname)'" sudo docker stop jupyter-$servicePort > docker-kill-${job_number}.sh
else
    echo sudo docker stop jupyter-$servicePort > docker-kill-${job_number}.sh
fi

# Create kill script. Needs to be here because we need the hostname of the compute node.
echo ssh "'$(hostname)'" sudo docker stop jupyter-$servicePort > docker-kill-${job_number}.sh
chmod 777 docker-kill-${job_number}.sh

sudo systemctl start docker

# Docker supports mounting directories that do not exist (singularity does not)

set -x
sudo docker run ${gpu_flag} --rm \
    -v /contrib:/contrib -v /lustre:/lustre -v ${HOME}:${HOME} \
    --name=novnc-$servicePort -p $servicePort:6901 __docker_repo__
