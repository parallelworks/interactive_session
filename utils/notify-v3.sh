#!/bin/bash
# Run this script right before starting the server
# This script needs to run in the user container to access the environment variable PW_API_KEY
source utils/load-env.sh
source resources/host/inputs.sh
source lib.sh

status="$1"

url="/workflows/${workflow_name}/${job_number}/view"

# Send notification if status is Running
echo "Posting notification"
curl -s \
    -X POST -H "Content-Type: application/json" \
    -d "{\"title\": \"Interactive workflow ${workflow_name} job ${job_number} is running\", \"href\": \"${url}\", \"type\": \"workflow\", \"subtype\": \"readyInteractive\"}" \
    https://${PW_PLATFORM_HOST}/api/v2/notifications \
    -H "Authorization: Basic $(echo ${PW_API_KEY}|base64)"

exit 0