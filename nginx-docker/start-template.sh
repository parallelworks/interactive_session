# This script runs in an environment with the following variables:

# Defined in the input form:
# - jobschedulertype
# - service_mount_directories
# - service_docker_repo

# Added by the workflow
# - job_number: PW job number, e.g.: 00001


# service_port: This value can be specified in the input form. Otherwise, the workflow 
#              selects any available port in the range 6000-9000

# Check if the user can execute commands with sudo
if ! sudo -v >/dev/null 2>&1; then
    displayErrorMessage "You do not have sudo access. Exiting."
fi

# Run docker container
container_name="nginx-${service_port}"

# CREATE CANCEL SCRIPT TO REMOVE DOCKER CONTAINER WHEN THE PW JOB IS CANCELED
if [[ ${jobschedulertype} == "CONTROLLER" ]]; then
    echo sudo "sudo docker stop ${container_name}" > docker-kill-${job_number}.sh
    echo sudo "sudo docker rm ${container_name}" >> docker-kill-${job_number}.sh
else
    # Create kill script. Needs to be here because we need the hostname of the compute node.
    echo ssh "'$(hostname)' sudo docker stop ${container_name}" > docker-kill-${job_number}.sh
    echo ssh "'$(hostname)' sudo docker rm ${container_name}" >> docker-kill-${job_number}.sh
fi

chmod 777 docker-kill-${job_number}.sh

# Start container
sudo service docker start

sudo -n docker run -d --name ${container_name} \
    ${service_mount_directories} -v ${HOME}:${HOME} \
    -p $service_port:80 \
    ${service_docker_repo}

sudo docker logs ${container_name}

# Notify platform that service is running
${sshusercontainer} "${pw_job_dir}/utils/notify.sh Running"

# If running docker with the -d option sleep here! 
# Do not exit this script until the job is canceled!
# Exiting this script before the job is canceled triggers the cancel script!
sleep 999999999
