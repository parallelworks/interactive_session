#!/bin/bash
source utils/load-env.sh
source resources/host/inputs.sh
source lib.sh

sed -i "s/.*JOB_STATUS.*/    \"JOB_STATUS\": \"Submitted\",/" service.json
echo "Submitting ssh job (wait for node to become available before connecting)..."
echo "$sshcmd 'bash -s' < ${session_sh}"
echo

# Run service
$sshcmd 'bash -s' < ${session_sh} #&> ${pw_job_dir}/session-${job_number}.out

if [ $? -eq 0 ]; then
    sed -i "s/.*JOB_STATUS.*/    \"JOB_STATUS\": \"Completed\",/" service.json
else
    sed -i "s/.*JOB_STATUS.*/    \"JOB_STATUS\": \"Failed\",/" service.json
fi

