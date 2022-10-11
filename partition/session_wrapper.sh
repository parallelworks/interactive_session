#!/bin/bash
echo
echo Arguments:
echo $@
echo

source lib.sh

parseArgs $@
sshcmd="ssh -o StrictHostKeyChecking=no ${controller}"

# create the script that will generate the session tunnel and run the interactive session app
# NOTE - in the below example there is an ~/.ssh/config definition of "localhost" control master that already points to the user container
#masterIp=$($sshcmd cat '~/.ssh/masterip')
masterIp=$($sshcmd hostname -I | cut -d' ' -f1) # Matthew: Master ip would usually be the internal ip
if [ -z ${masterIp} ]; then
    echo ERROR: masterIP variable is empty. Command:
    echo "$sshcmd hostname -I | cut -d' ' -f1"
    echo Exiting workflow
    exit 1
fi


# USER_CONTAINER_HOST
if [[ ${pooltype} == "slurmshv2" ]]; then
    USER_CONTAINER_HOST=${PW_USER_HOST} #${PARSL_CLIENT_HOST}
else
    USER_CONTAINER_HOST="localhost"
fi

if [[ "$USERMODE" == "k8s" ]];then
    # HAVE TO DO THIS FOR K8S NETWORKING TO EXPOSE THE PORT
    # WARNING: Maybe if controller contains user name (user@ip) you need to extract only the ip
    TUNNELCMD="ssh -J $masterIp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${USER_CONTAINER_HOST} \"ssh -J ${controller} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -L 0.0.0.0:$openPort:localhost:\$servicePort "'$(hostname)'"\""
else
    TUNNELCMD="ssh -J $masterIp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -R 0.0.0.0:$openPort:localhost:\$servicePort ${USER_CONTAINER_HOST}"
fi

# Initiallize session batch file:
echo "Generating session script"
session_sh=/pw/jobs/${job_number}/session.sh
echo "#!/bin/bash" > ${session_sh}
# SET SLURM DEFAULT VALUES:
if ! [ -z ${partition} ] && ! [[ "${partition}" == "default" ]]; then
    echo "#SBATCH --partition=${partition}" >> ${session_sh}
fi

if ! [ -z ${account} ] && ! [[ "${account}" == "default" ]]; then
    echo "#SBATCH --account=${account}" >> ${session_sh}
fi

if ! [ -z ${walltime} ] && ! [[ "${walltime}" == "default" ]]; then
    echo "#SBATCH --time=${walltime}" >> ${session_sh}
    swalltime=$(echo "${walltime}" | awk -F: '{ print ($1 * 3600) + ($2 * 60) + $3 + 60}')
else
    swalltime=9999
fi

if ! [ -z ${chdir} ] && ! [[ "${chdir}" == "default" ]]; then
    chdir=$(echo ${chdir} | sed "s|__job_number__|${job_number}|g")
    echo "#SBATCH --chdir=${chdir}" >> ${session_sh}
    ${sshcmd} mkdir -p ${chdir}
    remote_session_dir=${chdir}
else
    remote_session_dir="./"
fi

if [ -z ${numnodes} ]; then
    echo "#SBATCH --nodes=1" >> ${session_sh}
else
    echo "#SBATCH --nodes=${numnodes}" >> ${session_sh}
fi

if [[ "${exclusive}" == "True" ]]; then
    echo "#SBATCH --exclusive" >> ${session_sh}
fi

echo "#SBATCH --job-name=session-${job_number}" >> ${session_sh}
echo "#SBATCH --output=session-${job_number}.out" >> ${session_sh}
echo >> ${session_sh}

# ADD STREAMING
if [[ "${stream}" == "True" ]]; then
    stream_args="--host localhost --pushpath /pw/jobs/${job_number}/session-${job_number}.out --pushfile session-${job_number}.out --delay 30 --port ${PARSL_CLIENT_SSH_PORT} --masterIp ${masterIp}"
    stream_cmd="bash stream-${job_number}.sh ${stream_args} &"
    echo; echo "Streaming command:"; echo "${stream_cmd}"; echo
    echo ${stream_cmd} >> ${session_sh}
fi

cat >> ${session_sh} <<HERE
# Needed for emed
source ~/.bashrc
cd ${chdir}
if [[ "${pooltype}" == slurmshv2 ]]; then
    # register the worker to the coaster service
    ~/pworks/remote.sh
fi

#!/bin/bash
# These are not workflow parameters but need to be available to the service on the remote node!
FORWARDPATH=${FORWARDPATH}
IPADDRESS=${IPADDRESS}
openPort=${openPort}
masterIp=${masterIp}
USER_CONTAINER_HOST=${USER_CONTAINER_HOST}
controller=${controller}

# Find an available servicePort
minPort=6000
maxPort=9000
for port in \$(seq \${minPort} \${maxPort} | shuf); do
    out=\$(netstat -aln | grep LISTEN | grep \${port})
    if [ -z "\${out}" ]; then
        # To prevent multiple users from using the same available port --> Write file to reserve it
        portFile=/tmp/\${port}.port.used
        if ! [ -f "\${portFile}" ]; then
            touch \${portFile}
            export servicePort=\${port}
            break
        fi
    fi
done

if [ -z "\${servicePort}" ]; then
    echo "ERROR: No service port found in the range \${minPort}-\${maxPort} -- exiting session"
    exit 1
fi

echo
echo Starting interactive session - sessionPort: \$servicePort tunnelPort: $openPort
echo Test command to run in user container: telnet localhost $openPort
echo

# Create a port tunnel from the allocated compute node to the user container (or user node in some cases)

# run this in a screen so the blocking tunnel cleans up properly
echo "Running blocking ssh command..."
screen_bin=\$(which screen 2> /dev/null)
if [ -z "\${screen_bin}" ]; then
    echo "ERROR: screen is not installed in the system --> Exiting workflow"
    exit 1
    #echo "nohup ${TUNNELCMD} &"
    #nohup ${TUNNELCMD} &
    echo "${TUNNELCMD} &"
    ${TUNNELCMD} &
else
    echo "screen -d -m ${TUNNELCMD}"
    screen -d -m ${TUNNELCMD}
fi
echo "Exit code: \$?"
echo "Starting session..."
rm -f \${portFile}
HERE

# Add application-specific code
if [ -f "${start_service_sh}" ]; then
    cat ${start_service_sh} >> ${session_sh}
fi

# move the session file over
chmod 777 ${session_sh}
scp ${session_sh} ${controller}:${remote_session_dir}/session-${job_number}.sh
scp stream.sh ${controller}:${remote_session_dir}/stream-${job_number}.sh

echo
echo "Submitting slurm request (wait for node to become available before connecting)..."
echo
echo $sshcmd sbatch ${remote_session_dir}/session-${job_number}.sh
slurmjob=$($sshcmd sbatch ${remote_session_dir}/session-${job_number}.sh | tail -1 | awk -F ' ' '{print $4}')

if [[ "$slurmjob" == "" ]];then
    echo "ERROR submitting job - exiting the workflow"
    exit 1
fi

# CREATE KILL FILE:
# - When the job is killed PW runs /pw/jobs/job-number/kill.sh
# Initialize kill.sh
kill_sh=/pw/jobs/${job_number}/kill.sh
echo "#!/bin/bash" > ${kill_sh}
echo "echo Running ${kill_sh}" >> ${kill_sh}

# Add application-specific code
# WARNING: if part runs in a different directory than bash command! --> Use absolute paths!!
if [ -f "${kill_service_sh}" ]; then
    echo "Adding kill server script: ${kill_service_sh}"
    echo "$sshcmd 'bash -s' < ${kill_service_sh}" >> ${kill_sh}
fi
echo $sshcmd scancel $slurmjob >> ${kill_sh}
echo "echo Finished running ${kill_sh}" >> ${kill_sh}
chmod 777 ${kill_sh}

echo
echo "Submitted slurm job: $slurmjob"

sleep ${swalltime}
