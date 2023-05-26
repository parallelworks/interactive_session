#!/bin/bash
source lib.sh
source inputs.sh

export job_number=$(basename ${PWD})
echo "export job_number=${job_number}" >> inputs.sh

# export the users env file (for some reason not all systems are getting these upon execution)
while read LINE; do export "$LINE"; done < ~/.env

# Initialize service.html to prevent error from showing when you click in the eye icon
cp service.html.template service.html

echo
echo "JOB NUMBER:  ${job_number}"
echo "USER:        ${PW_USER}"
echo "DATE:        $(date)"
echo "DIRECTORY:   ${PWD}"
echo "COMMAND:     $0"
# Very useful to rerun a workflow with the exact same code version!
#commit_hash=$(git --git-dir=clone/.git log --pretty=format:'%h' -n 1)
#echo "COMMIT HASH: ${commit_hash}"
echo

export PW_JOB_PATH=$(pwd | sed "s|${HOME}||g")
echo "export PW_JOB_PATH=${PW_JOB_PATH}" >> inputs.sh

sed -i "s/__job_number__/${job_number}/g" inputs.sh
sed -i "s/__USER__/${PW_USER}/g" inputs.sh

# change permissions of run directly so we can execute all files
chmod 777 * -Rf
# Need to move files from utils directory to avoid updating the sparse checkout
mv utils/error.html .
mv utils/service.json .

# GER OPEN PORT FOR TUNNEL
getOpenPort

if [[ "$openPort" == "" ]]; then
    displayErrorMessage "ERROR - cannot find open port..."
    exit 1
fi
export openPort=${openPort}
echo "export openPort=${openPort}" >> inputs.sh

export USER_CONTAINER_HOST="usercontainer"
echo "export USER_CONTAINER_HOST=${USER_CONTAINER_HOST}" >> inputs.sh

source /pw/.miniconda3/etc/profile.d/conda.sh
conda activate

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

echo "Interactive Session Port: $openPort"

if ! [ -d "${service_name}" ]; then
    displayErrorMessage "ERROR: Directory ${service_name} was not found --> Service ${service_name} is not supported --> Exiting workflow"
    exit 1
fi

if ! [ -f "${service_name}/url.sh" ]; then
    displayErrorMessage "ERROR: Directory ${service_name}/url.sh was not found --> Add URL definition script --> Exiting workflow"
    exit 1
fi

#  CONTROLLER INFO
if [[ ${host_resource_name} == "user_workspace" ]]; then
    # Unless the user workspace has PBS or SLURM installed the only supported scheduler type is LOCAL
    export host_jobschedulertype="LOCAL"
    echo "export host_jobschedulertype=LOCAL" >> inputs.sh
fi
host_resource_name=$(echo ${host_resource_name} | sed "s/_//g" |  tr '[:upper:]' '[:lower:]')

pooltype=$(${CONDA_PYTHON_EXE} ${PWD}/utils/pool_api.py ${host_resource_name} type)
if [ -z "${pooltype}" ]; then
    displayErrorMessage "ERROR: Pool type not found - exiting the workflow"
    echo "${CONDA_PYTHON_EXE} ${PWD}/utils/pool_api.py ${host_resource_name} type"
    exit 1
fi

echo "Pool type: ${pooltype}"

# SET POOL WORK DIR:
# - This is only needed to
#   1. Run in a partition of a slurmshv2 to call the remote.sh script
#   2. If chdir is pw.conf or empty --> chdir=${poolworkdir}/pw/__job_number__
if [[ ${pooltype} == "slurmshv2" ]]; then
    export poolworkdir=$(${CONDA_PYTHON_EXE} ${PWD}/utils/pool_api.py ${host_resource_name} workdir)
    if [ -z "${poolworkdir}" ]; then
        displayErrorMessage "ERROR: Pool workdir not found - exiting the workflow"
        echo "${CONDA_PYTHON_EXE} ${PWD}/utils/pool_api.py ${host_resource_name} workdir"
        exit 1
    fi
else
    export poolworkdir=${HOME}
fi

 if [[ ${host_jobschedulertype} == "LOCAL" ]]; then
    export poolworkdir=/pw
fi

sed -i "s|__poolworkdir__|${poolworkdir}|g" inputs.sh

# SET chdir
export chdir=${poolworkdir}${PW_JOB_PATH}
echo "export chdir=${chdir}" >> inputs.sh

# GET CONTROLLER IP FROM PW API IF NOT SPECIFIED
if [ -z "${host_resource_name}" ]; then
    displayErrorMessage "ERROR: No service host was defined - exiting the workflow"
    exit 1
fi
controller=${host_resource_name}.clusters.pw
export controller=$(${CONDA_PYTHON_EXE} /swift-pw-bin/utils/cluster-ip-api-wrapper.py $controller)
export sshcmd="ssh -o StrictHostKeyChecking=no ${controller}"


if [ -z "${controller}" ]; then
    echo "controller=\$(\${CONDA_PYTHON_EXE} /swift-pw-bin/utils/cluster-ip-api-wrapper.py \$controller)"
    displayErrorMessage "ERROR: No controller was specified - exiting the workflow"
    exit 1
fi

# GET INTERNAL IP OF CONTROLLER NODE. 
# Get resource definition entry: Empty, internal ip or network name
export masterIp=$(${CONDA_PYTHON_EXE} ${PWD}/utils/pool_api.py ${host_resource_name} internalIp)
echo "export masterIp=${masterIp}" >> inputs.sh

if [[ "${masterIp}" != "" ]] && [[ "${masterIp}" != *"."* ]];then
    # If not empty and not an ip --> netowrk name
    masterIp=$($sshcmd "ifconfig ${masterIp} | sed -En -e 's/.*inet ([0-9.]+).*/\1/p'")
    echo "Using masterIp from interface: $masterIp"
fi

if [ -z "${masterIp}" ]; then
    # If empty use first internal ip
    export masterIp=$($sshcmd hostname -I | cut -d' ' -f1) 
fi

if [ -z ${masterIp} ]; then
    displayErrorMessage "ERROR: masterIP variable is empty - Exitig workflow"
    echo "Command: $sshcmd hostname -I | cut -d' ' -f1"
    exit 1
fi

# RUN IN CONTROLLER, SLURM PARTITION OR PBS QUEUE?
if [[ ${host_jobschedulertype} == "CONTROLLER" ]]; then
    echo "Submitting ssh job to ${controller}"
    session_wrapper_dir=controller
elif [[ ${host_jobschedulertype} == "LOCAL" ]]; then
    echo "Submitting ssh job to user container"
    session_wrapper_dir=local
else
    echo "Submitting ${host_jobschedulertype} job to ${controller}"
    session_wrapper_dir=partition

    # Get scheduler directives from input form (see this function in lib.sh)
    form_sched_directives=$(getSchedulerDirectivesFromInputForm)

    # Get scheduler directives enforced by PW:
    # Set job name, log paths and run directory
    if [[ ${host_jobschedulertype} == "SLURM" ]]; then
        pw_sched_directives=";--job-name=session-${job_number};--chdir=${chdir};--output=session-${job_number}.out"
    elif [[ ${host_jobschedulertype} == "PBS" ]]; then
        # PBS needs a queue to be specified!
        if [ -z "${_sch__d_q___}" ]; then
            is_queue_defined=$(echo ${host_scheduler_directives} | tr ';' '\n' | grep -e '-q___')
            if [ -z "${is_queue_defined}" ]; then
                displayErrorMessage "ERROR: PBS needs a queue to be defined! - exiting workflow"
                exit 1
            fi
        fi
        pw_sched_directives=";-N___session-${job_number};-o___${chdir}/session-${job_number}.out;-e___${chdir}/session-${job_number}.out;-S___/bin/bash"
    fi

    # Merge all directives in single param
    export scheduler_directives="${host_scheduler_directives};${form_sched_directives};${pw_sched_directives}"
    echo "export scheduler_directives=${scheduler_directived}"
fi

# SERVICE URL

echo "Generating session html"
source ${service_name}/url.sh
echo "export FORWARDPATH=${FORWARDPATH}" >> inputs.sh
echo "export IPADDRESS=${IPADDRESS}" >> inputs.sh
cp service.html.template service.html_

# FIXME: Move this to <service-name>/url.sh
if [[ "${service_name}" == "nicedcv" ]]; then
    URL="\"/sme/${openPort}/${URLEND}"
    sed -i "s|.*URL.*|    \"URL\": \"/sme\",|" service.json
else
    URL="\"/me/${openPort}/${URLEND}"
    sed -i "s|.*URL.*|    \"URL\": \"/me\",|" service.json
fi
sed -i "s|__URL__|${URL}|g" service.html_
# JSON values cannot contain quotes "
#URL_JSON=$(echo ${URL} | sed 's|\"|\\\\\"|g')
#sed -i "s|.*URL.*|    \"URL\": \"${URL_JSON}\",|" service.json
sed -i "s|.*PORT.*|    \"PORT\": \"${openPort}\",|" service.json
SLUG=$(echo ${URLEND} | sed 's|\"|\\\\\"|g')
sed -i "s|.*SLUG.*|    \"SLUG\": \"${SLUG}\",|" service.json

mv service.html_ service.html
echo

# RUNNING SESSION WRAPPER
bash ${session_wrapper_dir}/session_wrapper.sh 

# We don't want kill.sh to change the status to cancelled!
sed -i  "s/.*sed -i.*//" kill.sh  
bash kill.sh
