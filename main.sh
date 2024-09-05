#!/bin/bash
set -x
source utils/load-env.sh

sed -i 's|\\\\|\\|g' inputs.sh

./utils/steps/input_form_resource_wrapper.sh
./utils/steps/process_inputs_sh.sh
./utils/steps/controller_preprocessing.sh
# FIXME: Need to move files from utils directory to avoid updating the sparse checkout
cp utils/service.json .
./utils/steps/prepare_service_json.sh
./utils/steps/launch_job.sh

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
