#!/bin/bash
source /pw/.miniconda3/etc/profile.d/conda.sh
conda activate

# change permissions of run directly so we can execute all files
chmod 777 * -Rf
# Need to move files from utils directory to avoid updating the sparse checkout
cp utils/service.json .

source lib.sh

# Processing resource inputs
source /etc/profile.d/parallelworks.sh
source /etc/profile.d/parallelworks-env.sh
source /pw/.miniconda3/etc/profile.d/conda.sh
conda activate

if [ -f "/swift-pw-bin/utils/input_form_resource_wrapper.py" ]; then
    version=$(cat /swift-pw-bin/utils/input_form_resource_wrapper.py | grep VERSION | cut -d':' -f2)
    if [ -z "$version" ] || [ "$version" -lt 4 ]; then
        python utils/input_form_resource_wrapper.py
    else
        python /swift-pw-bin/utils/input_form_resource_wrapper.py
    fi
else
    python utils/input_form_resource_wrapper.py
fi

if ! [ -f "resources/host/inputs.sh" ]; then
    displayErrorMessage "ERROR - Missing file ./resources/host/inputs.sh. Resource wrapper failed"
fi
# Remove lines starting with "export host_" from inputs.sh
#     These were only needed by the input_form_resource_wrapper.sh
#     We want the inputs clean and in a single file because they are written to the submit scripts
sed -i '/^export pwrl_host_/d' inputs.sh
# Append processed inputs to input.sh
cat resources/host/inputs.sh >> inputs.sh

# Load and process inputs
source inputs.sh
export openPort=$(echo ${resource_ports} | sed "s|___| |g" | cut -d ' ' -f1)
if [[ "$openPort" == "" ]]; then
    displayErrorMessage "ERROR - cannot find open port..."
    exit 1
fi

echo "export openPort=${openPort}" >> inputs.sh
export sshcmd="ssh -o StrictHostKeyChecking=no ${resource_publicIp}"
echo "export sshcmd=\"${sshcmd}\"" >> inputs.sh 
# The resource wrapper only replaces placeholders in resource sections of the input form
# Therefore, we need to replace this here as well:
sed -i "s|__WORKDIR__|${resource_workdir}|g" inputs.sh
sed -i "s|__workdir__|${resource_workdir}|g" inputs.sh
sed -i "s|__PW_USER__|${PW_USER}|g" inputs.sh
sed -i "s|__pw_user__|${PW_USER}|g" inputs.sh
sed -i "s|__USER__|${resource_username}|g" inputs.sh
sed -i "s|__user__|${resource_username}|g" inputs.sh

source inputs.sh

# Obtain the service_name from any section of the XML
export service_name=$(cat inputs.sh | grep service_name | cut -d'=' -f2 | tr -d '"')
echo "export service_name=${service_name}" >> inputs.sh
if ! [ -d "${service_name}" ]; then
    displayErrorMessage "ERROR: Directory ${service_name} was not found --> Service ${service_name} is not supported --> Exiting workflow"
    exit 1
fi

export job_number=$(basename ${PWD})
export job_dir=$(pwd | rev | cut -d'/' -f1-2 | rev)
echo "export job_number=${job_number}" >> inputs.sh

# export the users env file (for some reason not all systems are getting these upon execution)
while read LINE; do export "$LINE"; done < ~/.env

export PW_JOB_PATH=$(pwd | sed "s|${HOME}||g")
echo "export PW_JOB_PATH=${PW_JOB_PATH}" >> inputs.sh

sed -i "s/__job_number__/${job_number}/g" inputs.sh

export USER_CONTAINER_HOST="usercontainer"
echo "export USER_CONTAINER_HOST=${USER_CONTAINER_HOST}" >> inputs.sh

# LOAD PLATFORM-SPECIFIC ENVIRONMENT:
env_sh=platforms/${PARSL_CLIENT_HOST}/env.sh
if ! [ -f "${env_sh}" ]; then
    env_sh=platforms/default/env.sh
fi
source ${env_sh}

if ! [ -f "${CONDA_PYTHON_EXE}" ]; then
    echo "WARNING: Environment variable CONDA_PYTHON_EXE is pointing to a missing file ${CONDA_PYTHON_EXE}!"
    echo "         Modifying its value: export CONDA_PYTHON_EXE=$(which python3)"
    # Wont work unless it has requests...
    export CONDA_PYTHON_EXE=$(which python3)
fi


# RUN IN CONTROLLER, SLURM PARTITION OR PBS QUEUE?
if [[ ${jobschedulertype} == "CONTROLLER" ]]; then
    echo "Submitting ssh job to ${resource_publicIp}"
    session_wrapper_dir=controller
elif [[ ${jobschedulertype} == "LOCAL" ]]; then
    echo "Submitting ssh job to user container"
    session_wrapper_dir=local
else
    echo "Submitting ${jobschedulertype} job to ${resource_publicIp}"
    session_wrapper_dir=partition
fi

# SERVICE URL
echo "Generating session html"
source ${service_name}/url.sh
echo "export FORWARDPATH=${FORWARDPATH}" >> inputs.sh
echo "export IPADDRESS=${IPADDRESS}" >> inputs.sh

# FIXME: Move this to <service-name>/url.sh
if [[ "${service_name}" == "nicedcv" ]]; then
    URL="\"/sme/${openPort}/${URLEND}"
    sed -i "s|.*URL.*|    \"URL\": \"/sme\",|" service.json
else
    URL="\"/me/${openPort}/${URLEND}"
    sed -i "s|.*URL.*|    \"URL\": \"/me\",|" service.json
fi
# JSON values cannot contain quotes "
#URL_JSON=$(echo ${URL} | sed 's|\"|\\\\\"|g')
#sed -i "s|.*URL.*|    \"URL\": \"${URL_JSON}\",|" service.json
sed -i "s|.*PORT.*|    \"PORT\": \"${openPort}\",|" service.json
SLUG=$(echo ${URLEND} | sed 's|\"|\\\\\"|g')
sed -i "s|.*SLUG.*|    \"SLUG\": \"${SLUG}\",|" service.json
echo

# RUNNING SESSION WRAPPER
if ! [ -f "${session_wrapper_dir}/session_wrapper.sh" ]; then
    displayErrorMessage "ERROR: File ${session_wrapper_dir}/session_wrapper.sh was not found --> Exiting workflow"
    exit 1
fi

bash ${session_wrapper_dir}/session_wrapper.sh 

if [ -f "kill.sh" ]; then
    # Only run if file exists. The kill.sh file is moved to _kill.sh after execution.
    # This is done to prevent the file form running twice which would generate errors.
    # We don't want kill.sh to change the status to cancelled!
    sed -i  "s/.*sed -i.*//" kill.sh  
    bash kill.sh
fi

exit 0
