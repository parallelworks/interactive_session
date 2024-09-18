#!/bin/bash
source utils/load-env.sh
source resources/host/inputs.sh
source lib.sh

if [ -z "$serviceHost" ]; then
    serviceHost=localhost
fi

# TUNNEL COMMANDS:
if [ -z "$service_port" ]; then
    SERVER_TUNNEL_CMD="ssh ${resource_ssh_usercontainer_options} -fN -R 0.0.0.0:$openPort:${serviceHost}:\$service_port ${USER_CONTAINER_HOST}"
else
    SERVER_TUNNEL_CMD="ssh ${resource_ssh_usercontainer_options} -fN -R 0.0.0.0:$openPort:${serviceHost}:$service_port ${USER_CONTAINER_HOST}"
fi
# Cannot have different port numbers on client and server or license checkout fails!
LICENSE_TUNNEL_CMD="ssh ${resource_ssh_usercontainer_options} -fN -L 0.0.0.0:${advanced_options_license_server_port}:localhost:${advanced_options_license_server_port} -L 0.0.0.0:${advanced_options_license_daemon_port}:localhost:${advanced_options_license_daemon_port} ${USER_CONTAINER_HOST}"

# Initiallize session batch file:
echo "Generating session script"
echo "#!/bin/bash" > ${session_sh}
cat resources/host/inputs.sh >> ${session_sh}
# Need this on some systems when running code with ssh
# - CAREFUL! This command can change your ${PWD} directory
echo "source ~/.bashrc" >>  ${session_sh}

if ! [ -z "${resource_jobdir}" ] && ! [[ "${resource_jobdir}" == "default" ]]; then
    echo "mkdir -p ${resource_jobdir}" >> ${session_sh}
    echo "cd ${resource_jobdir}" >> ${session_sh}
fi

cat >> ${session_sh} <<HERE
sshusercontainer="ssh ${resource_ssh_usercontainer_options} -f ${USER_CONTAINER_HOST}"

displayErrorMessage() {
    echo \$(date): \$1
    \${sshusercontainer} "sed -i \"s|.*ERROR_MESSAGE.*|    \\\\\"ERROR_MESSAGE\\\\\": \\\\\"\$1\\\\\"|\" ${pw_job_dir}/service.json"
    \${sshusercontainer} "sed -i \"s|.*JOB_STATUS.*|    \\\\\"JOB_STATUS\\\\\": \\\\\"FAILED\\\\\",|\" ${pw_job_dir}/service.json"
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

if [ -z "$service_port" ]; then
    # Find an available service_port
    service_port=\$(findAvailablePort)
    echo \${service_port} > service.port
fi

echo
echo Starting interactive session - sessionPort: \$service_port tunnelPort: $openPort
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
rm -f /tmp/\${service_port}.port.used 
HERE


# Add application-specific code
if [ -f "${service_name}/start-template.sh" ]; then
    cat "${service_name}/start-template.sh" >> ${session_sh}
fi

# Note that job is no longer running
echo >> ${session_sh}

chmod +x ${session_sh}