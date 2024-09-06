#!/bin/bash
source utils/load-env.sh
source resources/host/inputs.sh
set -x

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
