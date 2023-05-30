#!/bin/bash
sdir=$(dirname $0)
# For debugging
env > session_wrapper.env

source lib.sh

# TUNNEL COMMAND:
SERVER_TUNNEL_CMD="ssh -J $masterIp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -fN -R 0.0.0.0:$openPort:0.0.0.0:\$servicePort ${USER_CONTAINER_HOST}"
# Cannot have different port numbers on client and server or license checkout fails!
LICENSE_TUNNEL_CMD="ssh -J $masterIp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -fN -L 0.0.0.0:${license_server_port}:localhost:${license_server_port} -L 0.0.0.0:${license_daemon_port}:localhost:${license_daemon_port} ${USER_CONTAINER_HOST}"

# Initiallize session batch file:
echo "Generating session script"
export session_sh=${PW_JOB_PATH}/session.sh
echo "#!/bin/bash" > ${session_sh}

if [[ ${host_jobschedulertype} == "SLURM" ]]; then
    directive_prefix="#SBATCH"
    submit_cmd="sbatch"
    delete_cmd="scancel"
    stat_cmd="squeue"
elif [[ ${host_jobschedulertype} == "PBS" ]]; then
    directive_prefix="#PBS"
    submit_cmd="qsub"
    delete_cmd="qdel"
    stat_cmd="qstat"
else
    displayErrorMessage "ERROR: host_jobschedulertype <${host_jobschedulertype}> must be SLURM or PBS"
fi

if ! [ -z ${scheduler_directives} ]; then
    for sched_dir in $(echo ${scheduler_directives} | sed "s|;| |g"); do
        # Script DEFAULT_JOB_FILE_TEMPLATE.sh converts spaces to '___'. Here we undo the transformation.
        echo "${directive_prefix} ${sched_dir}" | sed "s|___| |g" >> ${session_sh}
    done
fi

echo >> ${session_sh}
cat inputs.sh >> ${session_sh}

# ADD RUNTIME FIXES FOR EACH PLATFORM
if ! [ -z ${RUNTIME_FIXES} ]; then
    echo ${RUNTIME_FIXES} | tr ';' '\n' >> ${session_sh}
fi

# SET SESSIONS' REMOTE DIRECTORY
${sshcmd} mkdir -p ${chdir}
remote_session_dir=${chdir}

# ADD STREAMING
if [[ "${advanced_options_stream}" == "True" ]]; then
    # Don't really know the extension of the --pushpath. Can't controll with PBS (FIXME)
    stream_args="--host ${USER_CONTAINER_HOST} --pushpath ${PW_JOB_PATH}/session-${job_number}.o --pushfile session-${job_number}.out --delay 30 --masterIp ${masterIp}"
    stream_cmd="bash stream-${job_number}.sh ${stream_args} &"
    echo; echo "Streaming command:"; echo "${stream_cmd}"; echo
    echo ${stream_cmd} >> ${session_sh}
fi

# MAKE SURE CONTROLLER NODES HAVE SSH ACCESS TO COMPUTE NODES:
$sshcmd cp "~/.ssh/id_rsa.pub" ${remote_session_dir}

cat >> ${session_sh} <<HERE
echo "Running in host \$(hostname)"
sshusercontainer="ssh -J $masterIp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${USER_CONTAINER_HOST}"

displayErrorMessage() {
    echo \$(date): \$1
    \${sshusercontainer} "sed -i \\"s|__ERROR_MESSAGE__|\$1|g\\" ${PW_PATH}${PW_JOB_PATH}/error.html"
    \${sshusercontainer} "cp ${PW_JOB_PATH}/error.html ${PW_PATH}${PW_JOB_PATH}/service.html"
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

cd ${chdir}
set -x

# MAKE SURE CONTROLLER NODES HAVE SSH ACCESS TO COMPUTE NODES:
pubkey=\$(cat ~/.ssh/authorized_keys | grep \"\$(cat id_rsa.pub)\")
if [ -z "\${pubkey}" ]; then
    echo "Adding public key of controller node to compute node ~/.ssh/authorized_keys"
    cat id_rsa.pub >> ~/.ssh/authorized_keys
fi

if [ -f "${poolworkdir}/pw/.pw/remote.sh" ]; then
    # NEW VERSION OF SLURMSHV2 PROVIDER
    echo "Running ${poolworkdir}/pw/.pw/remote.sh"
    ${poolworkdir}/pw/.pw/remote.sh
elif [ -f "${poolworkdir}/pw/remote.sh" ]; then
    echo "Running ${poolworkdir}/pw/remote.sh"
    ${poolworkdir}/pw/remote.sh
fi

# Find an available servicePort
servicePort=\$(findAvailablePort)
echo \${servicePort} > service.port

echo
echo Starting interactive session - sessionPort: \$servicePort tunnelPort: $openPort
echo Test command to run in user container: telnet localhost $openPort
echo

# Create a port tunnel from the allocated compute node to the user container (or user node in some cases)
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
rm -f \${portFile}
HERE

# Add application-specific code
if [ -f "${service_name}/start-template.sh" ]; then
    cat ${service_name}/start-template.sh >> ${session_sh}
fi

# move the session file over
chmod 777 ${session_sh}
scp ${session_sh} ${controller}:${remote_session_dir}/session-${job_number}.sh
scp stream.sh ${controller}:${remote_session_dir}/stream-${job_number}.sh

echo
echo "Submitting ${submit_cmd} request (wait for node to become available before connecting)..."
echo
echo $sshcmd ${submit_cmd} ${remote_session_dir}/session-${job_number}.sh

sed -i 's/.*Job status.*/Job status: Submitted/' service.html
sed -i "s/.*JOB_STATUS.*/    \"JOB_STATUS\": \"Submitted\",/" service.json

# Submit job and get job id
if [[ ${host_jobschedulertype} == "SLURM" ]]; then
    jobid=$($sshcmd ${submit_cmd} ${remote_session_dir}/session-${job_number}.sh | tail -1 | awk -F ' ' '{print $4}')
elif [[ ${host_jobschedulertype} == "PBS" ]]; then
    jobid=$($sshcmd ${submit_cmd} ${remote_session_dir}/session-${job_number}.sh)
fi

if [[ "${jobid}" == "" ]];then
    displayErrorMessage "ERROR submitting job - exiting the workflow"
fi

# CREATE KILL FILE:
# - When the job is killed PW runs ${PW_JOB_PATH}/job-number/kill.sh
# KILL_SSH: Part of the kill_sh that runs on the remote host with ssh
kill_ssh=${PW_JOB_PATH}/kill_ssh.sh
echo "#!/bin/bash" > ${kill_ssh}
cat inputs.sh >> ${kill_ssh} 
if [ -f "${service_name}/kill-template.sh" ]; then
    echo "Adding kill server script ${service_name}/kill-template.sh to ${kill_ssh}"
    cat ${service_name}/kill-template.sh >> ${kill_ssh}
fi
echo ${delete_cmd} ${jobid} >> ${kill_ssh}

# Initialize kill.sh
kill_sh=${PW_JOB_PATH}/kill.sh
echo "#!/bin/bash" > ${kill_sh}
echo "mv ${kill_sh} ${kill_sh}.completed" >> ${kill_sh}
cat inputs.sh >> ${kill_sh}
echo "echo Running ${kill_sh}" >> ${kill_sh}
echo "$sshcmd 'bash -s' < ${kill_ssh}" >> ${kill_sh}
echo "echo Finished running ${kill_sh}" >> ${kill_sh}
echo "sed -i 's/.*Job status.*/Job status: Cancelled/' ${PW_JOB_PATH}/service.html"  >> ${kill_sh}
echo "sed -i \"s/.*JOB_STATUS.*/    \\\"JOB_STATUS\\\": \\\"Cancelled\\\",/\"" ${PW_JOB_PATH}/service.json >> ${kill_sh}
echo "exit 0" >> ${kill_sh}
chmod 777 ${kill_sh}

echo
echo "Submitted slurm job: ${jobid}"


# Job status file writen by remote script:
while true; do    
    # squeue won't give you status of jobs that are not running or waiting to run
    # qstat returns the status of all recent jobs
    job_status=$($sshcmd ${stat_cmd} | grep ${jobid} | awk '{print $5}')
    sed -i "s/.*Job status.*/Job status: ${job_status}/" service.html
    sed -i "s/.*JOB_STATUS.*/    \"JOB_STATUS\": \"${job_status}\",/" service.json
    if [[ ${host_jobschedulertype} == "SLURM" ]]; then
        # If job status is empty job is no longer running
        if [ -z ${job_status} ]; then
            job_status=$($sshcmd sacct -j ${jobid}  --format=state | tail -n1)
            sed -i "s/.*Job status.*/Job status: ${job_status}/" service.html
            sed -i "s/.*JOB_STATUS.*/    \"JOB_STATUS\": \"${job_status}\",/" service.json
            break
        fi
    elif [[ ${host_jobschedulertype} == "PBS" ]]; then
        if [[ ${job_status} == "C" ]]; then
            break
        fi
    fi
    sleep 60
done

