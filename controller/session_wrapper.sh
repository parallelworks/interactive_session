#!/bin/bash
sdir=$(dirname $0)
# For debugging
env > session_wrapper.env

source lib.sh

# CREATE KILL FILE:
# - NEEDS TO BE MADE BEFORE RUNNING SESSION SCRIPT!
# - When the job is killed PW runs ${PW_JOB_PATH}/kill.sh
kill_ports="${openPort} ${advanced_options_license_server_port} ${advanced_options_license_daemon_port}"

# KILL_SSH: Part of the kill_sh that runs on the remote host with ssh
kill_ssh=${PW_JOB_PATH}/kill_ssh.sh
echo "#!/bin/bash" > ${kill_ssh}
cat inputs.sh >> ${kill_ssh} 
if [ -f "${service_name}/kill-template.sh" ]; then
    echo "Adding kill server script ${service_name}/kill-template.sh to ${kill_ssh}"
    cat ${service_name}/kill-template.sh >> ${kill_ssh}
fi
cat ${sdir}/kill_tunnels.sh >> ${kill_ssh}
cat ${sdir}/kill_session.sh >> ${kill_ssh}
sed -i "s/__KILL_PORTS__/${kill_ports}/g" ${kill_ssh}

# KILL_SH: File that runs on the user space
kill_sh=${PW_JOB_PATH}/kill.sh
echo "#!/bin/bash" > ${kill_sh}
echo "mv ${kill_sh} ${kill_sh}.completed" >> ${kill_sh}
cat inputs.sh >> ${kill_sh}
echo "echo Running ${kill_sh}" >> ${kill_sh}
# Add kill_ssh
cat >> ${kill_sh} <<HERE
$sshcmd 'bash -s' < ${kill_ssh}
bash ${sdir}/kill_tunnels.sh
echo Finished running ${kill_sh}
HERE
echo "sed -i \"s/.*JOB_STATUS.*/    \\\"JOB_STATUS\\\": \\\"Cancelled\\\",/\"" ${PW_JOB_PATH}/service.json >> ${kill_sh}
echo "exit 0" >> ${kill_sh}
chmod 777 ${kill_sh}

# TUNNEL COMMANDS:
SERVER_TUNNEL_CMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -fN -R 0.0.0.0:$openPort:localhost:\$servicePort ${USER_CONTAINER_HOST}"
# Cannot have different port numbers on client and server or license checkout fails!
LICENSE_TUNNEL_CMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -fN -L 0.0.0.0:${advanced_options_license_server_port}:localhost:${advanced_options_license_server_port} -L 0.0.0.0:${advanced_options_license_daemon_port}:localhost:${advanced_options_license_daemon_port} ${USER_CONTAINER_HOST}"

# Initiallize session batch file:
echo "Generating session script"
session_sh=${PW_JOB_PATH}/session.sh
echo "#!/bin/bash" > ${session_sh}
cat inputs.sh >> ${session_sh}
# Need this on some systems when running code with ssh
# - CAREFUL! This command can change your ${PWD} directory
echo "source ~/.bashrc" >>  ${session_sh}

if ! [ -z "${resource_jobdir}" ] && ! [[ "${resource_jobdir}" == "default" ]]; then
    echo "mkdir -p ${resource_jobdir}" >> ${session_sh}
    echo "cd ${resource_jobdir}" >> ${session_sh}
fi

cat >> ${session_sh} <<HERE
sshusercontainer="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${USER_CONTAINER_HOST}"

displayErrorMessage() {
    echo \$(date): \$1
    \${sshusercontainer} "sed -i \"s|.*ERROR_MESSAGE.*|    \\\\\"ERROR_MESSAGE\\\\\": \\\\\"\$1\\\\\"|\" ${PW_JOB_PATH}/service.json"
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

if ! [ -z "${advanced_options_license_env}" ]; then
    # Export license environment variable
    export ${advanced_options_license_env}=${advanced_options_license_server_port}@localhost
    # Create tunnel
    echo "${LICENSE_TUNNEL_CMD} </dev/null &>/dev/null &"
    ${LICENSE_TUNNEL_CMD} </dev/null &>/dev/null &
fi

echo "Exit code: \$?"
echo "Starting session..."
rm -f /tmp/\${servicePort}.port.used 
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
echo "Submitting ssh job (wait for node to become available before connecting)..."
echo "$sshcmd 'bash -s' < ${session_sh} &> ${PW_JOB_PATH}/session-${job_number}.out"
echo
sed -i "s/.*JOB_STATUS.*/    \"JOB_STATUS\": \"Running\",/" service.json
job_dir=$(pwd | rev | cut -d'/' -f1-2 | rev)
workflow_name=$(echo ${job_dir} | cut -d'/' -f1)
job_number=$(echo ${job_dir} | cut -d'/' -f2)
url="/workflows/${workflow_name}/${job_number}/view"
# needed for now to get the PW_PLATFORM_HOST and PW_API_KEY
source /etc/profile.d/parallelworks-env.sh
curl -s \
    -X POST -H "Content-Type: application/json" \
    -d "{\"title\": \"Interactive workflow ${workflow_name} job ${job_number} is running\", \"href\": \"${url}\", \"type\": \"workflow\", \"subtype\": \"readyInteractive\"}" \
    https://${PW_PLATFORM_HOST}/api/v2/notifications?key=${PW_API_KEY} &> /dev/null

$sshcmd 'bash -s' < ${session_sh} #&> ${PW_JOB_PATH}/session-${job_number}.out

if [ $? -eq 0 ]; then
    sed -i "s/.*JOB_STATUS.*/    \"JOB_STATUS\": \"Completed\",/" service.json
else
    sed -i "s/.*JOB_STATUS.*/    \"JOB_STATUS\": \"Failed\",/" service.json
fi

