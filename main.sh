#!/bin/bash
source lib.sh
job_number=$(basename ${PWD})

echo
echo "JOB NUMBER:  ${job_number}"
echo "USER:        ${PW_USER}"
echo "DATE:        $(date)"
# Very useful to rerun a workflow with the exact same code version!
#commit_hash=$(git log --pretty=format:'%h' -n 1)
commit_hash=$(git --git-dir=clone/.git log --pretty=format:'%h' -n 1)
echo "COMMIT HASH: ${commit_hash}"
echo

source lib.sh

echo "$0 $@"
parseArgs $@

getOpenPort

# LOAD PLATFORM-SPECIFIC ENVIRONMENT:
env_sh=platforms/${PARSL_CLIENT_HOST}/env.sh
if ! [ -f "${env_sh}" ]; then
    env_sh=platforms/default/env.sh
fi
source ${env_sh}

# SANITY CHECKS
if [[ "$openPort" == "" ]];then
    echo "ERROR - cannot find open port..."
    exit 1
fi

echo "Interactive Session Port: $openPort"

if [[ "$servicePort" == "" ]];then
    servicePort="8000"
fi

if ! [ -d "${service_name}" ]; then
    echod "ERROR: Directory ${service_name} was not found --> Service ${service_name} is not supported --> Exiting workflow"
    exit 1
fi

if ! [ -f "${service_name}/url.sh" ]; then
    echod "ERROR: Directory ${service_name}/url.sh was not found --> Add URL definition script --> Exiting workflow"
    exit 1
fi

#  CONTROLLER INFO
poolname=$(cat /pw/jobs/${job_number}/pw.conf | grep sites | grep -o -P '(?<=\[).*?(?=\])')
if [ -z "${poolname}" ]; then
    echo "ERROR: Pool name not found in /pw/jobs/${job_number}/pw.conf - exiting the workflow"
    exit 1
fi

pooltype=$(${CONDA_PYTHON_EXE} utils/get_pool_type.py ${poolname})
 if [ -z "${pooltype}" ]; then
    echo "ERROR: Pool type not found - exiting the workflow"
    echo "${CONDA_PYTHON_EXE} utils/get_pool_type.py ${poolname}"
    exit 1
fi

echo "Pool type: ${pooltype}"


if [[ ${controller} == "pw.conf" ]]; then
    if [ -z "${poolname}" ]; then
        echo "ERROR: Pool name not found in /pw/jobs/${job_number}/pw.conf - exiting the workflow"
        exit 1
    fi
    controller=${poolname}.clusters.pw
    if [[ ${pooltype} == "slurmshv2" ]]; then
        controller=$(${CONDA_PYTHON_EXE} /swift-pw-bin/utils/cluster-ip-api-wrapper.py $controller)
    fi
fi


if [ -z "${controller}" ]; then
    echo "ERROR: No controller was specified - exiting the workflow"
    exit 1
fi

# SERVICE URL
echo "Generating session html"
source ${service_name}/url.sh
cp service.html.template service.html
sed -i "s|__URLEND__|${URLEND}|g" service.html
sed -i "s/__FORWARDPATH__/$FORWARDPATH/g" service.html
sed -i "s/__IPADDRESS__/$IPADDRESS/g" service.html
sed -i "s/__OPENPORT__/$openPort/g" service.html
mv service.html /pw/jobs/${job_number}/service.html


# START / KILL SCRIPTS
# - Overwrite any argument by passing it before $@! E.g.: --servicePort 1234 $@
if [ -f "${service_name}/start-template.sh" ]; then
    start_service_sh=/pw/jobs/${job_number}/start-service.sh
    cp ${service_name}/start-template.sh ${start_service_sh}
    replace_templated_inputs ${start_service_sh} $@ --job_number ${job_number}
fi

if [ -f "${service_name}/kill-template.sh" ]; then
    kill_service_sh=/pw/jobs/${job_number}/kill-service.sh
    cp ${service_name}/kill-template.sh ${kill_service_sh}
    replace_templated_inputs ${kill_service_sh} $@ --job_number ${job_number}
fi


if [[ ${partition_or_controller} == "True" ]]; then
    echo "Submitting sbatch job to ${controller}"
    session_wrapper_dir=partition
else
    echo "Submitting ssh job to ${controller}"
    session_wrapper_dir=controller
fi

# - Overwrite any argument by passing it before $@! E.g.: --servicePort 1234 $@
bash ${session_wrapper_dir}/session_wrapper.sh $@ \
        --job_number ${job_number} \
        --openPort ${openPort} \
        --controller ${controller} \
        --start_service_sh ${start_service_sh} \
        --kill_service_sh ${kill_service_sh} \
        --pooltype ${pooltype}