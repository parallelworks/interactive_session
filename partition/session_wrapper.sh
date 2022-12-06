#!/bin/bash
echo
echo Arguments:
echo $@
echo
sdir=$(dirname $0)
source lib.sh

parseArgs $@
sshcmd="ssh -o StrictHostKeyChecking=no ${controller}"

# create the script that will generate the session tunnel and run the interactive session app
# NOTE - in the below example there is an ~/.ssh/config definition of "localhost" control master that already points to the user container
#masterIp=$($sshcmd cat '~/.ssh/masterip')
masterIp=$($sshcmd hostname -I | cut -d' ' -f1) # Matthew: Master ip would usually be the internal ip
if [ -z ${masterIp} ]; then
    echo "ERROR: masterIP variable is empty. Command:"
    echo "$sshcmd hostname -I | cut -d' ' -f1"
    echo Exiting workflow
    exit 1
fi

# check if the user is on a new container 
env | grep -q PW_USERCONTAINER_VERSION
NEW_USERCONTAINER="$?"

# TUNNEL COMMAND:
if [[ "$USERMODE" == "k8s" || "$NEW_USERCONTAINER" == "0" ]];then
    # HAVE TO DO THIS FOR K8S NETWORKING TO EXPOSE THE PORT
    # WARNING: Maybe if controller contains user name (user@ip) you need to extract only the ip
    TUNNELCMD="ssh -J $masterIp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${USER_CONTAINER_HOST} \"ssh -J ${controller} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -L 0.0.0.0:$openPort:localhost:\$servicePort "'$(hostname)'"\""
else
    TUNNELCMD="ssh -J $masterIp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -R 0.0.0.0:$openPort:localhost:\$servicePort ${USER_CONTAINER_HOST}"
fi

# Initiallize session batch file:
echo "Generating session script"
export session_sh=/pw/jobs/${job_number}/session.sh
echo "#!/bin/bash" > ${session_sh}

if [[ ${jobschedulertype} == "SLURM" ]]; then
    directive_prefix="SBATCH"
elif [[ ${jobschedulertype} == "PBS" ]]; then
    directive_prefix="PBS"
else
    echo "ERROR: jobschedulertype <${jobschedulertype}> must be SLURM or PBS"
    exit 1
fi

if ! [ -z ${scheduler_directives} ]; then
    for sched_dir in $(echo ${scheduler_directives} | sed "s|;| |g"); do
        echo "${directive_prefix} ${sched_dir}" >> ${session_sh}
    done
fi

echo >> ${session_sh}

if ! [ -z ${walltime} ] && ! [[ "${walltime}" == "default" ]]; then
    swalltime=$(echo "${walltime}" | awk -F: '{ print ($1 * 3600) + ($2 * 60) + $3 + 60}')
else
    swalltime=9999
fi

if ! [ -z ${chdir} ] && ! [[ "${chdir}" == "default" ]]; then
    ${sshcmd} mkdir -p ${chdir}
    remote_session_dir=${chdir}
else
    remote_session_dir="./"
fi

# ADD STREAMING
if [[ "${stream}" == "True" ]]; then
    stream_args="--host ${USER_CONTAINER_HOST} --pushpath /pw/jobs/${job_number}/session-${job_number}.out --pushfile session-${job_number}.out --delay 30 --masterIp ${masterIp}"
    stream_cmd="bash stream-${job_number}.sh ${stream_args} &"
    echo; echo "Streaming command:"; echo "${stream_cmd}"; echo
    echo ${stream_cmd} >> ${session_sh}
fi

# MAKE SURE CONTROLLER NODES HAVE SSH ACCESS TO COMPUTE NODES:
$sshcmd cp "~/.ssh/id_rsa.pub" ${remote_session_dir}

cat >> ${session_sh} <<HERE
# Needed for emed
source ~/.bashrc
cd ${chdir}
set -x
echo RUNNING > job.status
ssh ${ssh_options} $masterIp scp ${chdir}/job.status ${USER_CONTAINER_HOST}:/pw/jobs/${job_number}/job.status

# MAKE SURE CONTROLLER NODES HAVE SSH ACCESS TO COMPUTE NODES:
pubkey=\$(cat ~/.ssh/authorized_keys | grep \"\$(cat id_rsa.pub)\")
if [ -z "\${pubkey}" ]; then
    echo "Adding public key of controller node to compute node ~/.ssh/authorized_keys"
    cat id_rsa.pub >> ~/.ssh/authorized_keys
fi

if [ -f "${remote_sh}" ]; then
    echo "Running  ${remote_sh}"
    ${remote_sh}
fi

# These are not workflow parameters but need to be available to the service on the remote node!
NEW_USERCONTAINER=${NEW_USERCONTAINER}
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
    echo Screen not found. Attempting to install
    sudo -n yum install screen -y
fi

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

# Leave a blank line just in case!
cat >> ${session_sh} <<HERE

sacct -j ${SLURM_JOB_ID} --format=state | tail -n1 > job.status
ssh ${ssh_options} $masterIp scp ${chdir}/job.status ${USER_CONTAINER_HOST}:/pw/jobs/${job_number}/job.status
HERE


# move the session file over
chmod 777 ${session_sh}
scp ${session_sh} ${controller}:${remote_session_dir}/session-${job_number}.sh
scp stream.sh ${controller}:${remote_session_dir}/stream-${job_number}.sh

echo
echo "Submitting slurm request (wait for node to become available before connecting)..."
echo
echo $sshcmd sbatch ${remote_session_dir}/session-${job_number}.sh

sed -i 's/.*Job status.*/Job status: Submitted/' service.html

slurmjob=$($sshcmd sbatch ${remote_session_dir}/session-${job_number}.sh | tail -1 | awk -F ' ' '{print $4}')

if [[ "$slurmjob" == "" ]];then
    echo "ERROR submitting job - exiting the workflow"
    sed -i 's/.*Job status.*/Job status: Failed/' service.html
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
echo "sed -i 's/.*Job status.*/Job status: Cancelled/' /pw/jobs/${job_number}/service.html"  >> ${kill_sh}
chmod 777 ${kill_sh}

echo
echo "Submitted slurm job: $slurmjob"


# Job status file writen by remote script:
js_file="job.status"
while true; do
    if [ -f "${js_file}" ]; then
        job_status=$(cat ${js_file})
        sed -i "s/.*Job status.*/Job status: ${job_status}/" service.html
        if [[ "${job_status}" != "RUNNING" ]]; then
            break
        fi 
    fi
    sleep 30
done

