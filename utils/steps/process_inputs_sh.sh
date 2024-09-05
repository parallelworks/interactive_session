#!/bin/bash
source utils/load-env.sh
source resources/host/inputs.sh

export openPort=$(echo ${resource_ports} | sed "s|___| |g" | cut -d ' ' -f1)
if [[ "$openPort" == "" ]]; then
    displayErrorMessage "ERROR - cannot find open port..."
    exit 1
fi

echo "export openPort=${openPort}" >> resources/host/inputs.sh
export sshcmd="ssh -o StrictHostKeyChecking=no ${resource_publicIp}"
echo "export sshcmd=\"${sshcmd}\"" >> resources/host/inputs.sh
source resources/host/inputs.sh

# Obtain the service_name from any section of the XML
export service_name=$(cat resources/host/inputs.sh | grep service_name | cut -d'=' -f2 | tr -d '"')
echo "export service_name=${service_name}" >> resources/host/inputs.sh

if ! [ -d "${service_name}" ]; then
    displayErrorMessage "ERROR: Directory ${service_name} was not found --> Service ${service_name} is not supported --> Exiting workflow"
    exit 1
fi

sed -i "s/__job_number__/${job_number}/g" resources/host/inputs.sh

export USER_CONTAINER_HOST="usercontainer"
echo "export USER_CONTAINER_HOST=${USER_CONTAINER_HOST}" >> resources/host/inputs.sh

# RUN IN CONTROLLER, SLURM PARTITION OR PBS QUEUE?
if [[ ${jobschedulertype} == "CONTROLLER" ]]; then
    session_wrapper_dir=controller
elif [[ ${jobschedulertype} == "LOCAL" ]]; then
    session_wrapper_dir=local
else
    session_wrapper_dir=partition
fi
echo "export session_wrapper_dir=${session_wrapper_dir}" >> resources/host/inputs.sh