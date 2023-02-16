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

MWI_BASE_URL="/me/${openPort}/"

# Docker supports mounting directories that do not exist (singularity does not)
set -x

# https://docs.docker.com/config/containers/container-networking/
#    sudo docker run -it --rm -p 8888:8888 --shm-size=512M mathworks/matlab:r2022a -browser
#        cant run "-it" in the workflow! Fails with message: the input device is not a TTY
sudo -n docker run ${gpu_flag} -i --rm \
    -v /contrib:/contrib -v /lustre:/lustre -v ${HOME}:${HOME} \
    --name=matlab-$servicePort \
    -p $servicePort:$servicePort \
    --shm-size=512M \
    --env MWI_LOG_LEVEL=DEBUG \
    --env MWI_ENABLE_WEB_LOGGING=True \
    --env MWI_APP_HOST=0.0.0.0 \
    --env MWI_APP_PORT=$servicePort \
    --env MWI_ENABLE_TOKEN_AUTH=False \
    --env MWI_BASE_URL=${MWI_BASE_URL} \
    __docker_repo__ \
    -browser 

#     --env MWI_CUSTOM_HTTP_HEADERS='{"Content-Security-Policy": "frame-ancestors *cloud.parallel.works:* https://cloud.parallel.works:*;"}' \

sleep 9999