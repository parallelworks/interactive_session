#!/bin/bash
sdir=$(dirname $0)
echo
echo Arguments:
echo $@
echo

source lib.sh

parseArgs $@
sshcmd="ssh -o StrictHostKeyChecking=no ${controller}"
chdir=$(echo ${chdir} | sed "s|__job_number__|${job_number}|g")


# CREATE KILL FILE:
# - NEEDS TO BE MADE BEFORE RUNNING SESSION SCRIPT!
# - When the job is killed PW runs /pw/jobs/job-number/kill.sh
# Initialize kill.sh
kill_sh=/pw/jobs/${job_number}/kill.sh
kill_tunnels_sh=/pw/jobs/${job_number}/kill_tunnels_template.sh
kill_controller_session_sh=/pw/jobs/${job_number}/kill_session.sh

echo "#!/bin/bash" > ${kill_sh}
echo "echo Running ${kill_sh}" >> ${kill_sh}
# Add application-specific code
# WARNING: if part runs in a different directory than bash command! --> Use absolute paths!!
if [ -f "${kill_service_sh}" ]; then
    echo "Adding kill server script: ${kill_service_sh}"
    echo "$sshcmd 'bash -s' < ${kill_service_sh}" >> ${kill_sh}
fi
# Kill tunnels and child processes
cp ${sdir}/kill_tunnels_template.sh ${kill_tunnels_sh}
cp ${sdir}/kill_session_template.sh ${kill_controller_session_sh}

sed -i "s/__OPENPORT__/$openPort/g" ${kill_tunnels_sh}

sed -i "s/__job_number__/${job_number}/g" ${kill_controller_session_sh}
sed -i "s|__chdir__|${chdir}|g" ${kill_controller_session_sh}

cat >> ${kill_sh} <<HERE
$sshcmd 'bash -s' < ${kill_controller_session_sh}
$sshcmd 'bash -s' < ${kill_tunnels_sh}
bash ${kill_tunnels_sh}
HERE
echo "echo Finished running ${kill_sh}" >> ${kill_sh}
chmod 777 ${kill_sh}


# USER_CONTAINER_HOST FOR TUNNEL COMMAND:
if [[ ${pooltype} == "slurmshv2" ]]; then
    USER_CONTAINER_HOST=${PW_USER_HOST} #${PARSL_CLIENT_HOST}
else
    USER_CONTAINER_HOST="localhost"
fi


# Initiallize session batch file:
echo "Generating session script"
session_sh=/pw/jobs/${job_number}/session.sh
echo "#!/bin/bash" > ${session_sh}

if ! [ -z ${chdir} ] && ! [[ "${chdir}" == "default" ]]; then
    echo "mkdir -p ${chdir}" >> ${session_sh}
    echo "cd ${chdir}" >> ${session_sh}
fi

cat >> ${session_sh} <<HERE

# Note that job started running
echo \$$ > ${job_number}.pid

# These are not workflow parameters but need to be available to the service on the remote node!
FORWARDPATH=${FORWARDPATH}
IPADDRESS=${IPADDRESS}
openPort=${openPort}
USER_CONTAINER_HOST=${USER_CONTAINER_HOST}
USERMODE=${USERMODE}

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

# TUNNEL COMMAND:
if [[ "$USERMODE" == "k8s" ]];then
    # HAVE TO DO THIS FOR K8S NETWORKING TO EXPOSE THE PORT
    # WARNING: Maybe if controller contains user name (user@ip) you need to extract only the ip
    TUNNELCMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${USER_CONTAINER_HOST} \"ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -L 0.0.0.0:$openPort:localhost:\$servicePort "'\$(hostname)'"\""
else
    TUNNELCMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -R 0.0.0.0:$openPort:localhost:\$servicePort ${USER_CONTAINER_HOST}"
fi

# Create a port tunnel from the allocated compute node to the user container (or user node in some cases)
screen_bin=\$(which screen 2> /dev/null)
if [ -z "\${screen_bin}" ]; then
    PRE_TUNNELCMD=""
    POST_TUNNELCMD=" &"
else
    PRE_TUNNELCMD="screen -d -m "
    POST_TUNNELCMD=""
fi
echo "Running blocking ssh command..."
# run this in a screen so the blocking tunnel cleans up properly
echo "\${PRE_TUNNELCMD} \${TUNNELCMD} \${POST_TUNNELCMD}"
\${PRE_TUNNELCMD} \${TUNNELCMD} \${POST_TUNNELCMD}
echo "Exit code: \$?"
echo "Starting session..."
rm -f \${portFile}
HERE

# Add application-specific code
if [ -f "${start_service_sh}" ]; then
    cat ${start_service_sh} >> ${session_sh}
fi

# Note that job is no longer running
echo >> ${session_sh}

chmod 777 ${session_sh}

echo
echo "Submitting ssh job (wait for node to become available before connecting)..."
echo "$sshcmd 'bash -s' < ${session_sh} &> /pw/jobs/${job_number}/session-${job_number}.out"
echo
$sshcmd 'bash -s' < ${session_sh} &> /pw/jobs/${job_number}/session-${job_number}.out

