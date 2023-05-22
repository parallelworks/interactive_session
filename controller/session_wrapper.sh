#!/bin/bash
sdir=$(dirname $0)
# For debugging
env > session_wrapper.env

source lib.sh

# CREATE KILL FILE:
# - NEEDS TO BE MADE BEFORE RUNNING SESSION SCRIPT!
# - When the job is killed PW runs /pw/jobs/job-number/kill.sh
kill_ports="${openPort} ${license_server_port} ${license_daemon_port}"

# Initialize kill.sh
kill_sh=/pw/jobs/${job_number}/kill.sh
kill_tunnels_sh=/pw/jobs/${job_number}/kill_tunnels_template.sh
kill_controller_session_sh=/pw/jobs/${job_number}/kill_session.sh

echo "#!/bin/bash" > ${kill_sh}
cat inputs.sh >> ${kill_sh}
echo "echo Running ${kill_sh}" >> ${kill_sh}
# Add application-specific code
# WARNING: if part runs in a different directory than bash command! --> Use absolute paths!!
if [ -f "${service_name}/kill-template.sh" ]; then
    echo "Adding kill server script: ${service_name}/kill-template.sh"
    echo "$sshcmd 'bash -s' < ${service_name}/kill-template.sh" >> ${kill_sh}
fi
# Kill tunnels and child processes
cp ${sdir}/kill_tunnels_template.sh ${kill_tunnels_sh}
cp ${sdir}/kill_session_template.sh ${kill_controller_session_sh}

sed -i "s/__KILL_PORTS__/${kill_ports}/g" ${kill_tunnels_sh}

cat >> ${kill_sh} <<HERE
$sshcmd 'bash -s' < ${kill_controller_session_sh}
$sshcmd 'bash -s' < ${kill_tunnels_sh}
bash ${kill_tunnels_sh}
HERE
echo "echo Finished running ${kill_sh}" >> ${kill_sh}
echo "sed -i 's/.*Job status.*/Job status: Cancelled/' /pw/jobs/${job_number}/service.html" >> ${kill_sh}
echo "sed -i \"s/.*JOB_STATUS.*/    \\\"JOB_STATUS\\\": \\\"Cancelled\\\",/\"" /pw/jobs/${job_number}/service.json >> ${kill_sh}
chmod 777 ${kill_sh}

# TUNNEL COMMANDS:
SERVER_TUNNEL_CMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -fN -R 0.0.0.0:$openPort:localhost:\$servicePort ${USER_CONTAINER_HOST}"
# Cannot have different port numbers on client and server or license checkout fails!
LICENSE_TUNNEL_CMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -fN -L 0.0.0.0:${license_server_port}:localhost:${license_server_port} -L 0.0.0.0:${license_daemon_port}:localhost:${license_daemon_port} ${USER_CONTAINER_HOST}"

# Initiallize session batch file:
echo "Generating session script"
session_sh=/pw/jobs/${job_number}/session.sh
echo "#!/bin/bash" > ${session_sh}
cat inputs.sh >> ${session_sh}
# Need this on some systems when running code with ssh
# - CAREFUL! This command can change your ${PWD} directory
echo "source ~/.bashrc" >>  ${session_sh}

if ! [ -z "${chdir}" ] && ! [[ "${chdir}" == "default" ]]; then
    echo "mkdir -p ${chdir}" >> ${session_sh}
    echo "cd ${chdir}" >> ${session_sh}
fi

cat >> ${session_sh} <<HERE
sshusercontainer="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${USER_CONTAINER_HOST}"

displayErrorMessage() {
    echo \$(date): \$1
    \${sshusercontainer} "sed -i \\"s|__ERROR_MESSAGE__|\$1|g\\" ${PW_PATH}/pw/jobs/${job_number}/error.html"
    \${sshusercontainer} "cp /pw/jobs/${job_number}/error.html ${PW_PATH}/pw/jobs/${job_number}/service.html"
    \${sshusercontainer} "sed -i \"s|.*ERROR_MESSAGE.*|    \\\\\"ERROR_MESSAGE\\\\\": \\\\\"\$1\\\\\"|\" /pw/jobs/57236/service.json"
    exit 1
}

findAvailablePort() {
    # Find an available availablePort
    minPort=6000
    maxPort=9000
    for port in \$(seq \${minPort} \${maxPort} | shuf); do
        out=\$(netstat -aln | grep LISTEN | grep \${port})
        if [ -z "\${out}" ]; then
            # To prevent multiple users from using the same available port --> Write file to reserve it
            portFile=/tmp/\${port}.port.used
            if ! [ -f "\${portFile}" ]; then
                touch \${portFile}
                availablePort=\${port}
                echo \${port}
                break
            fi
        fi
    done

    if [ -z "\${availablePort}" ]; then
        displayErrorMessage "ERROR: No service port found in the range \${minPort}-\${maxPort} -- exiting session"
    fi
}


# Note that job started running
echo \$$ > ${job_number}.pid

# Find an available servicePort
servicePort=\$(findAvailablePort)
echo \${servicePort} > service.port

echo
echo Starting interactive session - sessionPort: \$servicePort tunnelPort: $openPort
echo Test command to run in user container: telnet localhost $openPort
echo

echo "${SERVER_TUNNEL_CMD} </dev/null &>/dev/null &"
${SERVER_TUNNEL_CMD} </dev/null &>/dev/null &

if ! [ -z "${license_env}" ]; then
    # Export license environment variable
    export ${license_env}=${license_server_port}@localhost
    # Create tunnel
    echo "${LICENSE_TUNNEL_CMD} </dev/null &>/dev/null &"
    ${LICENSE_TUNNEL_CMD} </dev/null &>/dev/null &
fi

echo "Exit code: \$?"
echo "Starting session..."
rm -f /tmp/\${servicePort}.port.used 
HERE

# Add application-specific code
if [ -f "${service_name}/start-template.sh" ]; then
    cat "${service_name}/start-template.sh" >> ${session_sh}
fi

# Note that job is no longer running
echo >> ${session_sh}

chmod 777 ${session_sh}

echo
echo "Submitting ssh job (wait for node to become available before connecting)..."
echo "$sshcmd 'bash -s' < ${session_sh} &> /pw/jobs/${job_number}/session-${job_number}.out"
echo
sed -i 's/.*Job status.*/Job status: Running/' service.html
sed -i "s/.*JOB_STATUS.*/    \"JOB_STATUS\": \"Running\",/" service.json
$sshcmd 'bash -s' < ${session_sh} &> /pw/jobs/${job_number}/session-${job_number}.out

if [ $? -eq 0 ]; then
    sed -i 's/.*Job status.*/Job status: Completed/' service.html
    sed -i "s/.*JOB_STATUS.*/    \"JOB_STATUS\": \"Completed\",/" service.json
else
    sed -i 's/.*Job status.*/Job status: Failed/' service.html
    sed -i "s/.*JOB_STATUS.*/    \"JOB_STATUS\": \"Failed\",/" service.json
fi

