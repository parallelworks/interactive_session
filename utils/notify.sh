#!/bin/bash
# Run this script right before starting the server
# This script needs to run in the user container to access the environment variable PW_API_KEY
# Use "ssh usercontainer /absolute/path/to/notify.sh" to launch the script

# Needed for now to get the PW_PLATFORM_HOST and PW_API_KEY
source /etc/profile.d/parallelworks-env.sh

pw_job_dir=$(dirname $(dirname $0))
status="$1"

source ${pw_job_dir}/inputs.sh

url="/workflows/${workflow_name}/${job_number}/view"

# Change job status
echo "Changing job status to ${status}"
sed -i "s/.*JOB_STATUS.*/    \"JOB_STATUS\": \"${status}\",/" ${pw_job_dir}/service.json

if [[ "${status}" != "Running" ]]; then
    exit 0
fi

# Send notification if status is Running
echo "Posting notification"
curl -s \
    -X POST -H "Content-Type: application/json" \
    -d "{\"title\": \"Interactive workflow ${workflow_name} job ${job_number} is running\", \"href\": \"${url}\", \"type\": \"workflow\", \"subtype\": \"readyInteractive\"}" \
    https://${PW_PLATFORM_HOST}/api/v2/notifications \
    -H "Authorization: Basic $(echo ${PW_API_KEY}|base64)"

exit 0