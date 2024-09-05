#!/bin/bash
set -x
source utils/load-env.sh

sed -i 's|\\\\|\\|g' inputs.sh

./utils/steps/input_form_resource_wrapper.sh 2>&1 | tee input_form_resource_wrapper.out
./utils/steps/process_inputs_sh.sh 2>&1 | tee process_inputs_sh.out
./utils/steps/controller_preprocessing.sh 2>&1 | tee controller_preprocessing.out
# FIXME: Need to move files from utils directory to avoid updating the sparse checkout
cp utils/service.json .
./utils/steps/prepare_service_json.sh 2>&1 | tee prepare_service_json.out
./utils/steps/initialize_cancel_script.sh 2>&1 | tee initialize_cancel_script.out
./utils/steps/create_session_script.sh 2>&1 | tee create_session_script.out
./utils/steps/launch_job.sh 2>&1 | tee launch_job.out

source resources/host/inputs.sh

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
