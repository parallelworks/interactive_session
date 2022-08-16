#!/bin/bash

echo
echo Arguments:
echo $@
echo

source lib

parseArgs $@

getOpenPort

if [[ "$openPort" == "" ]];then
    echo "ERROR - cannot find open port..."
    exit 1
fi

echo "Interactive Session Port: $openPort"

if [[ "$servicePort" == "" ]];then
    servicePort="8000"
fi

echo "Generating session file..."
cp service.html.template service.html.tmp

if [ ! -z "${KUBERNETES_PORT}" ];then
    USERMODE="k8s"
else
    USERMODE="docker"
fi

if [[ "$USERMODE" == "k8s" ]];then
    FORWARDPATH="pwide-kube"
    IPADDRESS="$(hostname -I | xargs)"
else
    FORWARDPATH="pwide"
    IPADDRESS="$PW_USER_HOST"
fi

sed -i "s/__FORWARDPATH__/$FORWARDPATH/" service.html.tmp
sed -i "s/__IPADDRESS__/$IPADDRESS/" service.html.tmp
sed -i "s/__OPENPORT__/$openPort/" service.html.tmp

mv service.html.tmp service.html

processPoolProperties

if [[ "$poolProperties" == "" ]];then
    echo "ERROR - cannot get pool properties..."
    exit 1
fi

echo "Getting submit host IP address (will wait until acquired)..."
getResourceInfo

if [[ "$submitHostIp" == "" ]];then
    echo "ERROR - cannot get resource master ip..."
    exit 1
fi

echo "Submitting job to $submitHostIp"

sshuser=$(echo "$poolProperties" | python -c 'import sys,json;print(json.load(sys.stdin)["pwuser"])')
sshhost=$(echo $submitHostIp)

sshcmd="ssh -o StrictHostKeyChecking=no $sshuser@$sshhost"

# create the script that will generate the session tunnel and run the interactive session app
# NOTE - in the below example there is an ~/.ssh/config definition of "localhost" control master that already points to the user container
masterIp=$($sshcmd cat '~/.ssh/masterip')

if [[ "$USERMODE" == "k8s" ]];then
    # HAVE TO DO THIS FOR K8S NETWORKING TO EXPOSE THE PORT
    TUNNELCMD="ssh -J $masterIp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null localhost \"ssh -J $submitHostIp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -L 0.0.0.0:$openPort:localhost:$servicePort "'$(hostname)'"\""
else
    TUNNELCMD="ssh -J $masterIp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -R 0.0.0.0:$openPort:localhost:$servicePort localhost"
fi

# Initiallize session batch file:
echo "#!/bin/bash" > session.sh
# SET SLURM DEFAULT VALUES:
if ! [ -z ${partition} ] && ! [[ "${walltime}" == "default" ]]; then
    echo "#SBATCH --partition=${partition}" >> session.sh
fi

if ! [ -z ${walltime} ] && ! [[ "${walltime}" == "default" ]]; then
    echo "#SBATCH --time=${walltime}" >> session.sh
fi

if [ -z ${numnodes} ]; then
    echo "#SBATCH --nodes=1" >> session.sh
else
    echo "#SBATCH --nodes=${numnodes}" >> session.sh
fi


if [[ "${exclusive}" == "True" ]]; then
    echo "#SBATCH --exclusive" >> session.sh
fi

cat >> session.sh <<HERE
#SBATCH --job-name=session-${job_number}
#SBATCH --output=session-${job_number}.out

echo
echo Starting interactive session - sessionPort: $servicePort tunnelPort: $openPort
echo Test command to run in user container: telnet localhost $openPort
echo

# create a port tunnel from the allocated compute node to the user container (or user node in some cases)
echo "Running blocking ssh command..."
# run this in a screen so the blocking tunnel cleans up properly
screen -d -m $TUNNELCMD

# start the app
# nc -kl --no-shutdown $servicePort
echo "Starting session..."

HERE

# Add application-specific code
app_session_sh=../app_session.sh
if [ -f "${app_session_sh}" ]; then
    cat ${app_session_sh} >> session.sh
fi
replace_templated_inputs session.sh $@

# move the session file over
chmod 777 session.sh
scp session.sh $sshuser@$sshhost:session-${job_number}.sh


echo
echo "Submitting slurm request (wait for node to become available before connecting)..."
echo
echo $sshcmd sbatch session-${job_number}.sh
slurmjob=$($sshcmd sbatch session-${job_number}.sh | tail -1 | awk -F ' ' '{print $4}')

if [[ "$slurmjob" == "" ]];then
    echo "ERROR submitting job - exiting the workflow"
    exit 1
fi

# CREATE KILL FILE:
# - When the job is killed PW runs /pw/jobs/job-number/kill.sh
# Initialize kill.sh
echo "#!/bin/bash" > kill.sh
# Add application-specific code
app_kill_sh=app_kill.sh
if [ -f "${app_kill_sh}" ]; then
    echo "$sshcmd 'bash -s' < ${app_kill_sh}" >> kill.sh
fi
echo $sshcmd scancel $slurmjob >> kill.sh

replace_templated_inputs kill.sh $@

chmod 777 kill.sh

echo
echo "Submitted slurm job: $slurmjob"

sleep 99999
