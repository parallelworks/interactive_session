#!/bin/bash

source lib.sh

parseArgs $@

# SANITY CHECKS
if ! [ -d "${service_name}" ]; then
    echod "ERROR: Directory ${service_name} was not found --> ${service_name} is not supported --> Exiting workflow"
    exit 1
fi

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

if ! [ -f "${service_name}/url.sh" ]; then
    echod "ERROR: Directory ${service_name}/url.sh was not found --> Add URL definition script --> Exiting workflow"
    exit 1
fi

# SERVICE URL
source ${service_name}/url.sh
sed -i "s|__URLEND__|${URLEND}|g" service.html.template
sed -i "s/__FORWARDPATH__/$FORWARDPATH/" service.html.template
sed -i "s/__IPADDRESS__/$IPADDRESS/" service.html.template


bash session_wrapper.sh $@ --start_service_sh ${start_service_sh} --kill_service_sh ${kill_service_sh}
