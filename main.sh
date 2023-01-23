#!/bin/bash

source lib.sh
export job_number=$(basename ${PWD})

# export the users env file (for some reason not all systems are getting these upon execution)
while read LINE; do export "$LINE"; done < ~/.env

echo
echo "JOB NUMBER:  ${job_number}"
echo "USER:        ${PW_USER}"
echo "DATE:        $(date)"
# Very useful to rerun a workflow with the exact same code version!
#commit_hash=$(git --git-dir=clone/.git log --pretty=format:'%h' -n 1)
#echo "COMMIT HASH: ${commit_hash}"
echo

# change permissions of run directly so we can execute all files
chmod 777 * -Rf
# Need to move files from utils directory to avoid updating the sparse checkout
mv utils/error.html .
mv utils/service.json .

# Replace special placeholder since \$(whoami) and \${PW_USER} don't work everywhere and ${job_number} is not known
# Preserve single quota (--pname 'pval') with ${@@Q}
wfargs="$(echo $@ | sed "s|__job_number__|${job_number}|g" | sed "s|__USER__|${PW_USER}|g")"

echo "$0 $wfargs"

parseArgs $wfargs

# GER OPEN PORT FOR TUNNEL
getOpenPort

if [[ "$openPort" == "" ]]; then
    displayErrorMessage "ERROR - cannot find open port..."
    exit 1
fi
export openPort=${openPort}

export USER_CONTAINER_HOST="usercontainer"

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
# We need to know the poolname to get the pooltype (always) and the controller IP address (sometimes)
if [ -z "${poolname}" ] || [[ "${poolname}" == "pw.conf" ]]; then
    poolname=$(cat /pw/jobs/${job_number}/pw.conf | grep sites | grep -o -P '(?<=\[).*?(?=\])')
    if [ -z "${poolname}" ]; then
        displayErrorMessage "ERROR: Pool name not found in /pw/jobs/${job_number}/pw.conf - exiting the workflow"
        exit 1
    fi
fi
# No underscores and only lowercase
poolname=$(echo ${poolname} | sed "s/_//g" |  tr '[:upper:]' '[:lower:]')

pooltype=$(${CONDA_PYTHON_EXE} ${PWD}/utils/pool_api.py ${poolname} type)
if [ -z "${pooltype}" ]; then
    displayErrorMessage "ERROR: Pool type not found - exiting the workflow"
    echo "${CONDA_PYTHON_EXE} ${PWD}/utils/pool_api.py ${poolname} type"
    exit 1
fi

echo "Pool type: ${pooltype}"

# SET POOL WORK DIR:
# - This is only needed to
#   1. Run in a partition of a slurmshv2 to call the remote.sh script
#   2. If chdir is pw.conf or empty --> chdir=${poolworkdir}/pw/__job_number__
if [[ ${pooltype} == "slurmshv2" ]]; then
    poolworkdir=$(${CONDA_PYTHON_EXE} ${PWD}/utils/pool_api.py ${poolname} workdir)
    if [ -z "${poolworkdir}" ]; then
        displayErrorMessage "ERROR: Pool workdir not found - exiting the workflow"
        echo "${CONDA_PYTHON_EXE} ${PWD}/utils/pool_api.py ${poolname} workdir"
        exit 1
    fi
else
    poolworkdir=${HOME}
fi

wfargs="$(echo ${wfargs} | sed "s|__poolworkdir__|${poolworkdir}|g")"


# SET chdir
export chdir=${poolworkdir}/pw/jobs/${job_number}/

# GET CONTROLLER IP FROM PW API IF NOT SPECIFIED
if [ -z "${poolname}" ]; then
    displayErrorMessage "ERROR: Pool name not found in /pw/jobs/${job_number}/pw.conf - exiting the workflow"
    exit 1
fi
controller=${poolname}.clusters.pw
export controller=$(${CONDA_PYTHON_EXE} /swift-pw-bin/utils/cluster-ip-api-wrapper.py $controller)
export sshcmd="ssh -o StrictHostKeyChecking=no ${controller}"


if [ -z "${controller}" ]; then
    echo "controller=\$(\${CONDA_PYTHON_EXE} /swift-pw-bin/utils/cluster-ip-api-wrapper.py \$controller)"
    displayErrorMessage "ERROR: No controller was specified - exiting the workflow"
    exit 1
fi

# GET INTERNAL IP OF CONTROLLER NODE. 
# Get resource definition entry: Empty, internal ip or network name
export masterIp=$(${CONDA_PYTHON_EXE} ${PWD}/utils/pool_api.py ${poolname} internalIp)

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
if [[ ${jobschedulertype} == "CONTROLLER" ]]; then
    # FIXME: Rename to compute_or_controller
    export partition_or_controller="False"
    echo "Submitting ssh job to ${controller}"
    session_wrapper_dir=controller
else
    # FIXME: Rename to compute_or_controller
    export partition_or_controller="True"
    echo "Submitting ${jobschedulertype} job to ${controller}"
    session_wrapper_dir=partition
    if [[ ${pooltype} == "slurmshv2" ]]; then
        export remote_sh=${poolworkdir}/pw/remote.sh
    fi

    # Get scheduler directives from input form (see this function in lib.sh)
    form_sched_directives=$(getSchedulerDirectivesFromInputForm ${wfargs})

    # Get scheduler directives enforced by PW:
    # Set job name, log paths and run directory
    if [[ ${jobschedulertype} == "SLURM" ]]; then
        pw_sched_directives=";--job-name=session-${job_number};--chdir=${chdir};--output=session-${job_number}.out"
    elif [[ ${jobschedulertype} == "PBS" ]]; then
        # PBS needs a queue to be specified!
        if [ -z "${_sch__d_q___}" ]; then
            is_queue_defined=$(echo ${scheduler_directives} | tr ';' '\n' | grep -e '-q___')
            if [ -z "${is_queue_defined}" ]; then
                displayErrorMessage "ERROR: PBS needs a queue to be defined! - exiting workflow"
                exit 1
            fi
        fi
        pw_sched_directives=";-N___session-${job_number};-o___${chdir}/session-${job_number}.out;-e___${chdir}/session-${job_number}.out;-S___/bin/bash"
    fi

    # Merge all directives in single param and in wfargs
    export scheduler_directives="${scheduler_directives};${form_sched_directives};${pw_sched_directives}"
fi

# SERVICE URL
# FIXME: This entire section needs cleaning. Got dirty with the new usercontainer.
# check if the user is on a new container 
env | grep -q PW_USERCONTAINER_VERSION
# Needs to be exported for services like Jupyter that require a base url --NotebookApp.base_url
export NEW_USERCONTAINER="$?"

echo "Generating session html"
replace_templated_inputs ${service_name}/url.sh $wfargs
source ${service_name}/url.sh
cp service.html.template service.html_

if [[ "$NEW_USERCONTAINER" == "0" ]];then
    URL="\"/me/${openPort}/${URLEND}"
    sed -i "s|.*URL.*|    \"URL\": \"/me\",|" service.json
else
    URL="\"/${FORWARDPATH}/${IPADDRESS}/${openPort}/${URLEND}"
    sed -i "s|.*URL.*|    \"URL\": \"/${FORWARDPATH}/${IPADDRESS}\",|" service.json
fi
sed -i "s|__URL__|${URL}|g" service.html_
# JSON values cannot contain quotes "
#URL_JSON=$(echo ${URL} | sed 's|\"|\\\\\"|g')
#sed -i "s|.*URL.*|    \"URL\": \"${URL_JSON}\",|" service.json
sed -i "s|.*PORT.*|    \"PORT\": \"${openPort}\",|" service.json
SLUG=$(echo ${URLEND} | sed 's|\"|\\\\\"|g')
sed -i "s|.*SLUG.*|    \"SLUG\": \"${SLUG}\",|" service.json

mv service.html_ /pw/jobs/${job_number}/service.html
echo

# START / KILL SCRIPTS
if [ -f "${service_name}/start-template.sh" ]; then
    export start_service_sh=/pw/jobs/${job_number}/start-service.sh
    echo "Generating ${start_service_sh}"
    cp ${service_name}/start-template.sh ${start_service_sh}
    replace_templated_inputs ${start_service_sh} $wfargs --_pw_job_number ${job_number} --_pw_chdir ${chdir} --_pw_partition_or_controller ${partition_or_controller}
    echo
fi

if [ -f "${service_name}/kill-template.sh" ]; then
    export kill_service_sh=/pw/jobs/${job_number}/kill-service.sh
    echo "Generating ${kill_service_sh}"
    cp ${service_name}/kill-template.sh ${kill_service_sh}
    replace_templated_inputs ${kill_service_sh} $wfargs --_pw_job_number ${job_number} --_pw_chdir ${chdir} --_pw_partition_or_controller ${partition_or_controller}
    echo
fi

# RUNNING SESSION WRAPPER
bash ${session_wrapper_dir}/session_wrapper.sh 

# We don't want kill.sh to change the status to cancelled!
sed -i  "s/.*sed -i.*//" kill.sh  
bash kill.sh
