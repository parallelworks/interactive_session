#!/bin/bash
source utils/load-env.sh
source resources/host/inputs.sh

set -x

if [ -z "${openPort}" ]; then
    export openPort=$(echo ${resource_ports} | sed "s|___| |g" | cut -d ' ' -f1)
    if [[ "$openPort" == "" ]]; then
        displayErrorMessage "ERROR - cannot find open port..."
        exit 1
    fi
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
    displayErrorMessage "ERROR: Unsupported option ${jobschedulertype}=LOCAL"
    exit 1
else
    session_wrapper_dir=partition
fi
echo "export session_wrapper_dir=${session_wrapper_dir}" >> resources/host/inputs.sh


# Paths to the scripts to kill the jobs
echo "export kill_ssh=${pw_job_dir}/kill_ssh.sh" >> resources/host/inputs.sh
echo "export kill_sh=${pw_job_dir}/kill.sh" >> resources/host/inputs.sh

# Path to the session script
echo "export session_sh=${pw_job_dir}/session.sh"  >> resources/host/inputs.sh