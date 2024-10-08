#!/bin/bash
source utils/load-env.sh
source resources/host/inputs.sh
source lib.sh

if [ -z "$serviceHost" ]; then
    serviceHost="0.0.0.0"
fi

# TUNNEL COMMAND:
if [ -z "$service_port" ]; then
    SERVER_TUNNEL_CMD="ssh ${resource_ssh_usercontainer_options} -fN -R 0.0.0.0:$openPort:${serviceHost}:\${service_port} ${USER_CONTAINER_HOST}"
else
    SERVER_TUNNEL_CMD="ssh ${resource_ssh_usercontainer_options} -fN -R 0.0.0.0:$openPort:${serviceHost}:${service_port} ${USER_CONTAINER_HOST}"
fi
# Cannot have different port numbers on client and server or license checkout fails!
LICENSE_TUNNEL_CMD="ssh ${resource_ssh_usercontainer_options} -fN -L 0.0.0.0:${advanced_options_license_server_port}:localhost:${advanced_options_license_server_port} -L 0.0.0.0:${advanced_options_license_daemon_port}:localhost:${advanced_options_license_daemon_port} ${USER_CONTAINER_HOST}"

# Initiallize session batch file:
echo "Generating session script"
cp resources/host/batch_header.sh ${session_sh}

echo >> ${session_sh}
cat resources/host/inputs.sh >> ${session_sh}

# ADD STREAMING
if [[ "${advanced_options_stream}" != "false" ]]; then
    # Don't really know the extension of the --pushpath. Can't controll with PBS (FIXME)
    stream_args="--host ${USER_CONTAINER_HOST} --pushpath ${pw_job_dir}/stream.out --pushfile logs.out --delay 30 --masterIp ${resource_privateIp}"
    stream_cmd="bash stream-${job_number}.sh ${stream_args} &"
    echo; echo "Streaming command:"; echo "${stream_cmd}"; echo
    echo ${stream_cmd} >> ${session_sh}
fi

cat >> ${session_sh} <<HERE
# In case the job directory is not shared between the controller and compute nodes
mkdir -p ${resource_jobdir}
cd ${resource_jobdir}

echo "Running in host \$(hostname)"
sshusercontainer="ssh ${resource_ssh_usercontainer_options} -f ${USER_CONTAINER_HOST}"
ssh ${resource_ssh_usercontainer_options} -f ${USER_CONTAINER_HOST} hostname

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

cd ${resource_jobdir}
set -x

# MAKE SURE CONTROLLER NODES HAVE SSH ACCESS TO COMPUTE NODES:
pubkey=\$(cat ~/.ssh/authorized_keys | grep \"\$(cat id_rsa.pub)\")
if [ -z "\${pubkey}" ]; then
    echo "Adding public key of controller node to compute node ~/.ssh/authorized_keys"
    cat id_rsa.pub >> ~/.ssh/authorized_keys
fi

if [ -f "${resource_workdir}/pw/.pw/remote.sh" ]; then
    # NEW VERSION OF SLURMSHV2 PROVIDER
    echo "Running ${resource_workdir}/pw/.pw/remote.sh"
    ${resource_workdir}/pw/.pw/remote.sh
elif [ -f "${resource_workdir}/pw/remote.sh" ]; then
    echo "Running ${resource_workdir}/pw/remote.sh"
    ${resource_workdir}/pw/remote.sh
fi

# Find an available service_port. Could be anywhere in the form (<section_name>_service_port)
service_port=$(env | grep service_port | cut -d'=' -f2)
if [ -z "\${service_port}" ]; then
    service_port=\$(findAvailablePort)
fi
echo \${service_port} > service.port

echo
echo Starting interactive session - sessionPort: \$service_port tunnelPort: $openPort
echo Test command to run in user container: telnet localhost $openPort
echo

# Create a port tunnel from the allocated compute node to the user container (or user node in some cases)
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

rm -f \${portFile}
HERE

# Add application-specific code
if [ -f "${service_name}/start-template.sh" ]; then
    cat ${service_name}/start-template.sh >> ${session_sh}
fi

# move the session file over
chmod +x ${session_sh}

