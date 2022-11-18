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


# Docker supports mounting directories that do not exist (singularity does not)
set -x

# https://docs.docker.com/config/containers/container-networking/
#    sudo docker run -it --rm -p 8888:8888 --shm-size=512M mathworks/matlab:r2022a -browser

sudo -n docker run ${gpu_flag} -it --rm \
    -v /contrib:/contrib -v /lustre:/lustre -v ${HOME}:${HOME} \
    --name=matlab-$servicePort \
    -p 8888:$servicePort \
    --shm-size=512M \
    __docker_repo__ \
    -browser 


sleep 9999