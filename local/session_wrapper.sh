#!/bin/bash
sdir=$(dirname $0)
# For debugging
env > session_wrapper.env

source lib.sh

# CREATE KILL FILE:
# - NEEDS TO BE MADE BEFORE RUNNING SESSION SCRIPT!
# - When the job is killed PW runs /pw/jobs/job-number/kill.sh
# Initialize kill.sh
kill_sh=/pw/jobs/${job_number}/kill.sh

echo "#!/bin/bash" > ${kill_sh}
echo "echo Running ${kill_sh}" >> ${kill_sh}
# Add application-specific code
# WARNING: if part runs in a different directory than bash command! --> Use absolute paths!!
if [ -f "${kill_service_sh}" ]; then
    echo "Adding kill server script: ${kill_service_sh}"
    echo "bash ${kill_service_sh}" >> ${kill_sh}
fi
echo "echo Finished running ${kill_sh}" >> ${kill_sh}
echo "sed -i 's/.*Job status.*/Job status: Cancelled/' /pw/jobs/${job_number}/service.html" >> ${kill_sh}
echo "sed -i \"s/.*JOB_STATUS.*/    \\\"JOB_STATUS\\\": \\\"Cancelled\\\",/\"" /pw/jobs/${job_number}/service.json >> ${kill_sh}
chmod 777 ${kill_sh}

# Initiallize session batch file:
echo "Generating session script"
session_sh=/pw/jobs/${job_number}/session.sh
echo "#!/bin/bash" > ${session_sh}
cat >> ${session_sh} <<HERE
source lib.sh
# Note that job started running
echo \$$ > ${job_number}.pid

# These are not workflow parameters but need to be available to the service on the remote node!
FORWARDPATH=${FORWARDPATH}
NEW_USERCONTAINER=${NEW_USERCONTAINER}
IPADDRESS=${IPADDRESS}
openPort=${openPort}
USER_CONTAINER_HOST=${USER_CONTAINER_HOST}
USERMODE=${USERMODE}
masterIp=${masterIp}
# When running apps locally there is no tunnel and ports are the same
servicePort=${openPort} 

if [ -z "\${servicePort}" ]; then
    displayErrorMessage "ERROR: No service port found in the range \${minPort}-\${maxPort} -- exiting session"
fi

echo
echo Starting interactive session - sessionPort: ${openPort}
echo
echo "Starting session..."
HERE

# Add application-specific code
if [ -f "${start_service_sh}" ]; then
    cat ${start_service_sh} >> ${session_sh}
fi

# Note that job is no longer running
echo >> ${session_sh}

chmod 777 ${session_sh}

echo
echo "Submitting job:"
echo "bash ${session_sh} &> /pw/jobs/${job_number}/session-${job_number}.out"
echo
sed -i 's/.*Job status.*/Job status: Running/' service.html
sed -i "s/.*JOB_STATUS.*/    \"JOB_STATUS\": \"Running\",/" service.json
bash ${session_sh} &> /pw/jobs/${job_number}/session-${job_number}.out

if [ $? -eq 0 ]; then
    sed -i 's/.*Job status.*/Job status: Completed/' service.html
    sed -i "s/.*JOB_STATUS.*/    \"JOB_STATUS\": \"Completed\",/" service.json
else
    sed -i 's/.*Job status.*/Job status: Failed/' service.html
    sed -i "s/.*JOB_STATUS.*/    \"JOB_STATUS\": \"Failed\",/" service.json
fi
