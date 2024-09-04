#!/bin/bash
source utils/load-env.sh

sed -i 's|\\\\|\\|g' inputs.sh

./utils/steps/input_form_resource_wrapper.sh

# Need to move files from utils directory to avoid updating the sparse checkout
cp utils/service.json .

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
source inputs.sh

# Obtain the service_name from any section of the XML
export service_name=$(cat inputs.sh | grep service_name | cut -d'=' -f2 | tr -d '"')
echo "export service_name=${service_name}" >> inputs.sh

if ! [ -d "${service_name}" ]; then
    displayErrorMessage "ERROR: Directory ${service_name} was not found --> Service ${service_name} is not supported --> Exiting workflow"
    exit 1
fi

export PW_JOB_PATH=$(pwd | sed "s|${HOME}||g")
echo "export PW_JOB_PATH=${PW_JOB_PATH}" >> inputs.sh

sed -i "s/__job_number__/${job_number}/g" inputs.sh

export USER_CONTAINER_HOST="usercontainer"
echo "export USER_CONTAINER_HOST=${USER_CONTAINER_HOST}" >> inputs.sh


if ! [ -f "${CONDA_PYTHON_EXE}" ]; then
    echo "WARNING: Environment variable CONDA_PYTHON_EXE is pointing to a missing file ${CONDA_PYTHON_EXE}!"
    echo "         Modifying its value: export CONDA_PYTHON_EXE=$(which python3)"
    # Wont work unless it has requests...
    export CONDA_PYTHON_EXE=$(which python3)
fi

# RUN CONTROLLER PREPROCESSING STEP
if [ -f "${service_name}/controller.sh" ]; then
    echo; echo; echo "RUNNING PREPROCESSING STEP"
    echo '#!/bin/bash' > controller.sh
    cat inputs.sh >> controller.sh
    cat ${service_name}/controller.sh >> controller.sh
    echo "$sshcmd 'bash -s' < controller.sh"
    $sshcmd 'bash -s' < controller.sh
fi

job_status=$(jq -r '.JOB_STATUS' service.json)
if [ "$job_status" == "FAILED" ]; then
    echo "Job status is FAILED."
    exit 1
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

# FIXME: Move this to <service-name>/url.sh
if [[ "${service_name}" == "nicedcv" ]] || [[ "${service_name}" == "hammerspace" ]]; then
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

job_status=$(cat service.json | jq -r '.JOB_STATUS' | tr '[:upper:]' '[:lower:]')
# Check if JOB_STATUS is "FAILED" or "failed"
if [[ "$job_status" == "failed" ]]; then
    echo "JOB FAILED"
    cat service.json | jq -r '.ERROR_MESSAGE'
    exit 1
else
    exit 0
fi
