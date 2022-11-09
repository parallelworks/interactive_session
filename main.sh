#!/bin/bash
# Need to know which pool types are slurm or PBS:
slurmpooltypes="gclusterv2 pclusterv2 azclusterv2 awsclusterv2 slurmshv2"
pbspooltypes="pbsshv2"

source lib.sh
job_number=$(basename ${PWD})

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

source lib.sh
# Replace special placeholder since \$(whoami) and \${PW_USER} don't work everywhere and ${job_number} is not known
wfargs="$(echo $@ | sed "s|__job_number__|${job_number}|g" | sed "s|__USER__|${PW_USER}|g") --job_number ${job_number}"


echo "$0 $wfargs"

parseArgs $wfargs

getOpenPort

###############################
# SANITY CHECKS AND DEFAULTS: #
###############################
USER_CONTAINER_HOST="usercontainer"

if [[ "$openPort" == "" ]];then
    echo "ERROR - cannot find open port..."
    exit 1
fi

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
    echod "ERROR: Directory ${service_name} was not found --> Service ${service_name} is not supported --> Exiting workflow"
    exit 1
fi

if ! [ -f "${service_name}/url.sh" ]; then
    echod "ERROR: Directory ${service_name}/url.sh was not found --> Add URL definition script --> Exiting workflow"
    exit 1
fi

#  CONTROLLER INFO
# We need to know the poolname to get the pooltype (always) and the controller IP address (sometimes)
if [ -z "${poolname}" ] || [[ "${poolname}" == "pw.conf" ]]; then
    poolname=$(cat /pw/jobs/${job_number}/pw.conf | grep sites | grep -o -P '(?<=\[).*?(?=\])')
    if [ -z "${poolname}" ]; then
        echo "ERROR: Pool name not found in /pw/jobs/${job_number}/pw.conf - exiting the workflow"
        exit 1
    fi
fi
# No underscores and only lowercase
poolname=$(echo ${poolname} | sed "s/_//g" |  tr '[:upper:]' '[:lower:]')

pooltype=$(${CONDA_PYTHON_EXE} ${PWD}/utils/pool_api.py ${poolname} type)
if [ -z "${pooltype}" ]; then
    echo "ERROR: Pool type not found - exiting the workflow"
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
        echo "ERROR: Pool workdir not found - exiting the workflow"
        echo "${CONDA_PYTHON_EXE} ${PWD}/utils/pool_api.py ${poolname} workdir"
        exit 1
    fi
else
    poolworkdir=${HOME}
fi

wfargs="$(echo ${wfargs} | sed "s|__poolworkdir__|${poolworkdir}|g")"


# SET DEFAULT chdir
if [ -z "${chdir}" ]; then
    wfargs=$(echo ${wfargs} | sed "s|--chdir||g")
    wfargs="${wfargs} --chdir ${poolworkdir}/pw/jobs/${job_number}/"
    elif [[ ${chdir} == "pw.conf" ]]; then
    wfargs=$(echo ${wfargs} | sed "s|--chdir pw.conf|--chdir ${poolworkdir}/pw/jobs/${job_number}/|g")
fi


# GET CONTROLLER IP FROM PW API IF NOT SPECIFIED
if [ -z "${controller}" ] || [[ ${controller} == "pw.conf" ]]; then
    if [ -z "${poolname}" ]; then
        echo "ERROR: Pool name not found in /pw/jobs/${job_number}/pw.conf - exiting the workflow"
        exit 1
    fi
    controller=${poolname}.clusters.pw
    controller=$(${CONDA_PYTHON_EXE} /swift-pw-bin/utils/cluster-ip-api-wrapper.py $controller)
fi


if [ -z "${controller}" ]; then
    echo "ERROR: No controller was specified - exiting the workflow"
    exit 1
fi

# RUN IN CONTROLLER OR PARTITION NODE
if [[ ${partition_or_controller} == "True" ]]; then
    echo "Submitting sbatch job to ${controller}"
    session_wrapper_dir=partition
    
    if [[ ${pooltype} == "slurmshv2" ]]; then
        wfargs="${wfargs} --remote_sh ${poolworkdir}/pw/remote.sh"
    fi
    
    # GET JOB SCHEDULER TYPE
    if [[ " ${slurmpooltypes} " == *" ${pooltype} "* ]]; then
        jobschedulertype=slurm
        elif [[ " ${pbspooltypes} " == *" ${pooltype} "* ]]; then
        jobschedulertype=pbs
    else
        echo "ERROR: Pool type <${pooltype}> not present in slurm types <${slurmpooltypes}> or pbs types <${pbspooltypes}>"
        exit 1
    fi
    wfargs="${wfargs} --jobschedulertype ${jobschedulertype}"
else
    echo "Submitting ssh job to ${controller}"
    session_wrapper_dir=controller
fi

# SERVICE URL
echo "Generating session html"
replace_templated_inputs ${service_name}/url.sh $wfargs
source ${service_name}/url.sh
cp service.html.template service.html_

# check if the user is on a new container 
env | grep -q PW_USERCONTAINER_VERSION
NEW_USERCONTAINER="$?"

if [[ "$NEW_USERCONTAINER" == "0" ]];then
    sed -i "s/\/__FORWARDPATH__\/__IPADDRESS__\/__OPENPORT__\//\/me\/$openPort\//g" service.html.template

else
    sed -i "s/__FORWARDPATH__/$FORWARDPATH/g" service.html_
    sed -i "s/__IPADDRESS__/$IPADDRESS/g" service.html_
    sed -i "s/__OPENPORT__/$openPort/g" service.html_
fi
sed -i "s|__URLEND__|${URLEND}|g" service.html_

mv service.html_ /pw/jobs/${job_number}/service.html
echo

# START / KILL SCRIPTS
if [ -f "${service_name}/start-template.sh" ]; then
    start_service_sh=/pw/jobs/${job_number}/start-service.sh
    echo "Generating ${start_service_sh}"
    cp ${service_name}/start-template.sh ${start_service_sh}
    replace_templated_inputs ${start_service_sh} $wfargs
    echo
fi

if [ -f "${service_name}/kill-template.sh" ]; then
    kill_service_sh=/pw/jobs/${job_number}/kill-service.sh
    echo "Generating ${kill_service_sh}"
    cp ${service_name}/kill-template.sh ${kill_service_sh}
    replace_templated_inputs ${kill_service_sh} $wfargs
    echo
fi

bash ${session_wrapper_dir}/session_wrapper.sh $wfargs \
--openPort ${openPort} \
--controller ${controller} \
--start_service_sh ${start_service_sh} \
--kill_service_sh ${kill_service_sh} \
--USER_CONTAINER_HOST ${USER_CONTAINER_HOST}

# We don't want kill.sh to change the status to cancelled!
sed -i 's/sed//' kill.sh
bash kill.sh
