# This script runs in an environment with the following variables:

# Defined in the input form:
# - jobschedulertype
# - service_mount_directories
# - service_docker_repo

# Added by the workflow
# - job_number: PW job number, e.g.: 00001


# service_port: This value can be specified in the input form. Otherwise, the workflow 
#              selects any available port

# Check if the user can execute commands with sudo
if ! sudo -v >/dev/null 2>&1; then
    displayErrorMessage "You do not have sudo access. Exiting."
fi

set -x

# Run docker container
container_name="postgres-${service_port}"

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

if ! [ -z "${service_db}" ]; then
    POSTGRES_DB_ENV=" -e POSTGRES_DB=${service_db}"
fi

# Start container
sudo mkdir -p /postgres-data

sudo systemctl start docker
sudo -n docker run -d --name ${container_name} \
    ${service_mount_directories} \
    -p $service_port:5432 \
    -e PGDATA=/var/lib/postgresql/data/pgdata \
	-v /postgres-data:/var/lib/postgresql/data \
    -e POSTGRES_USER=${service_user} -e POSTGRES_PASSWORD=${service_password} ${POSTGRES_DB_ENV} \
    ${service_image}

sleep 5

sudo docker logs ${container_name}

# If running docker with the -d option sleep here! 
# Do not exit this script until the job is canceled!
# Exiting this script before the job is canceled triggers the cancel script!
#sleep inf
