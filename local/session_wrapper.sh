#!/bin/bash
sdir=$(dirname $0)
# For debugging
env > session_wrapper.env

source lib.sh

# CREATE KILL FILE:
# - NEEDS TO BE MADE BEFORE RUNNING SESSION SCRIPT!
# - When the job is killed PW runs ${PW_JOB_PATH}/kill.sh
kill_ports="${openPort}"
# Initialize kill.sh
kill_sh=${PW_JOB_PATH}/kill.sh

echo "#!/bin/bash" > ${kill_sh}
echo "echo Running ${kill_sh}" >> ${kill_sh}
cat inputs.sh >> ${kill_sh} 
# Add application-specific code
# WARNING: if part runs in a different directory than bash command! --> Use absolute paths!!
if [ -f "${service_name}/kill-template.sh" ]; then
    echo "Adding kill server script: ${service_name}/kill-template.sh"
    echo "bash ${service_name}/kill-template.sh" >> ${kill_sh}
fi
cat  ${sdir}/clear_ports.sh  >> ${kill_sh}
sed -i "s/__KILL_PORTS__/${kill_ports}/g" ${kill_sh}
echo "kill \$(ps -x | grep ${job_number} | grep ${workflow_name} | grep -v grep | awk '{print \$1}')" >> ${kill_sh}
echo "echo Finished running ${kill_sh}" >> ${kill_sh}
echo "sed -i \"s/.*JOB_STATUS.*/    \\\"JOB_STATUS\\\": \\\"Cancelled\\\",/\"" ${PW_JOB_PATH}/service.json >> ${kill_sh}
chmod 777 ${kill_sh}

# Initiallize session batch file:
echo "Generating session script"
session_sh=${PW_JOB_PATH}/session.sh
echo "#!/bin/bash" > ${session_sh}
echo "mv ${kill_sh} ${kill_sh}.completed" >> ${kill_sh}
cat inputs.sh >> ${session_sh}
cat >> ${session_sh} <<HERE
source lib.sh
# Note that job started running
echo \$$ > ${job_number}.pid

# When running apps locally there is no tunnel and ports are the same
service_port=${openPort} 

if [ -z "\${service_port}" ]; then
    displayErrorMessage "ERROR: No service port found in the range \${minPort}-\${maxPort} -- exiting session"
fi

echo
echo Starting interactive session - sessionPort: ${openPort}
echo
echo "Starting session..."
HERE

# Load server environment
if ! [ -z "${service_load_env}" ]; then
    echo ${service_load_env} >> ${session_sh}
fi

# Add application-specific code
if [ -f "${service_name}/start-template.sh" ]; then
    cat "${service_name}/start-template.sh" >> ${session_sh}
fi

# Note that job is no longer running
echo >> ${session_sh}

chmod 777 ${session_sh}

echo
echo "Submitting job:"
echo "bash ${session_sh}"
echo

sed -i "s/.*JOB_STATUS.*/    \"JOB_STATUS\": \"Submitted\",/" service.json

# Run service
bash ${session_sh} 

if [ $? -eq 0 ]; then
    sed -i "s/.*JOB_STATUS.*/    \"JOB_STATUS\": \"Completed\",/" service.json
else
    sed -i "s/.*JOB_STATUS.*/    \"JOB_STATUS\": \"Failed\",/" service.json
fi
