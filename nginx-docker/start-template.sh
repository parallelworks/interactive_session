# This script runs in an environment with the following variables:

# Defined in the input form:
# - jobschedulertype
# - service_mount_directories
# - service_docker_repo

# Added by the workflow
# - job_number: PW job number, e.g.: 00001


# servicePort: This value can be specified in the input form. Otherwise, the workflow 
#              selects any available port in the range 6000-9000


# CREATE CANCEL SCRIPT TO REMOVE DOCKER CONTAINER WHEN THE PW JOB IS CANCELED
if [[ ${jobschedulertype} == "CONTROLLER" ]]; then
    echo sudo -n docker stop jupyter-$servicePort > docker-kill-${job_number}.sh
else
    # Create kill script. Needs to be here because we need the hostname of the compute node.
    echo ssh "'$(hostname)'" sudo -n docker stop jupyter-$servicePort > docker-kill-${job_number}.sh
fi

chmod 777 docker-kill-${job_number}.sh

# Make sure docker service is started
sudo -n systemctl start docker

# Run docker container
sudo -n docker run --rm \
    ${service_mount_directories} -v ${HOME}:${HOME} \
    --name=nginx-$servicePort \
    -p $servicePort:80 \
    ${service_docker_repo}


# If running docker with the -d option sleep here! 
# Do not exit this script until the job is canceled!
# Exiting this script before the job is canceled triggers the cancel script!
sleep 99999