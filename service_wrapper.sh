#!/bin/bash

source lib.sh

echo "service wrapper: $@"
parseArgs $@

getOpenPort

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
    echod "ERROR: Directory ${service_name} was not found --> ${service_name} is not supported --> Exiting workflow"
    exit 1
fi

if ! [ -f "${service_name}/url.sh" ]; then
    echod "ERROR: Directory ${service_name}/url.sh was not found --> Add URL definition script --> Exiting workflow"
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
if [ -f "${service_name}/start-template.sh" ]; then
    start_service_sh=/pw/jobs/${job_number}/start-service.sh
    cp ${service_name}/start-template.sh ${start_service_sh}
    replace_templated_inputs ${start_service_sh} $@
fi

if [ -f "${service_name}/kill-template.sh" ]; then
    kill_service_sh=/pw/jobs/${job_number}/kill-service.sh
    cp ${service_name}/kill-template.sh ${kill_service_sh}
    replace_templated_inputs ${kill_service_sh} $@
fi


if [[ ${partition_or_controller} == "True" ]]; then
    bash session_wrapper.sh $@ --start_service_sh ${start_service_sh} --kill_service_sh ${kill_service_sh}
else
    exit 0
    #bash session_wrapper.sh $@ --start_service_sh ${start_service_sh} --kill_service_sh ${kill_service_sh}
fi
