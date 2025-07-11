#!/bin/bash
source utils/load-env.sh
source resources/host/inputs.sh

# TRANSFER FILES TO REMOTE DIRECTORY
scp -p ${session_sh} ${resource_publicIp}:${resource_jobdir}/session-${job_number}.sh

echo
echo "Submitting ${submit_cmd} request (wait for node to become available before connecting)..."
echo
echo $sshcmd ${submit_cmd} ${resource_jobdir}/session-${job_number}.sh

# START STREAMING
${sshcmd} touch ${resource_jobdir}/logs.out
${sshcmd} tail -f ${resource_jobdir}/logs.out &
echo "kill $! # kill streaming" >> ${kill_sh}

# Submit job and get job id
if [[ ${jobschedulertype} == "SLURM" ]]; then
    jobid=$($sshcmd ${submit_cmd} ${resource_jobdir}/session-${job_number}.sh | tail -1 | awk -F ' ' '{print $4}')
elif [[ ${jobschedulertype} == "PBS" ]]; then
    jobid=$($sshcmd ${submit_cmd} ${resource_jobdir}/session-${job_number}.sh)
fi

if [[ "${jobid}" == "" ]];then
    displayErrorMessage "ERROR submitting job - exiting the workflow"
fi

echo ${cancel_cmd} ${jobid} >> ${kill_ssh}

echo
echo "Submitted job: ${jobid}"

get_slurm_job_status() {
    # Get the header line to determine the column index corresponding to the job status
    if [ -z "${SQUEUE_HEADER}" ]; then
        export SQUEUE_HEADER="$(eval "$sshcmd ${status_cmd}" | awk 'NR==1')"
    fi
    status_column=$(echo "${SQUEUE_HEADER}" | awk '{ for (i=1; i<=NF; i++) if ($i ~ /^S/) { print i; exit } }')
    status_response=$(eval $sshcmd ${status_cmd} | awk -v jobid="${jobid}" '$1 == jobid')
    echo "${SQUEUE_HEADER}"
    echo "${status_response}"
    export job_status=$(echo ${status_response} | awk -v id="${jobid}" -v col="$status_column" '{print $col}')
}

get_pbs_job_status() {
    # Get the header line to determine the column index corresponding to the job status
    if [ -z "${QSTAT_HEADER}" ]; then
        export QSTAT_HEADER="$(eval "$sshcmd ${status_cmd}" | awk 'NR==1')"
    fi
    status_response=$(eval $sshcmd ${status_cmd} 2>/dev/null | grep "\<${jobid}\>")
    echo "${QSTAT_HEADER}"
    echo "${status_response}"
    export job_status="$(eval $sshcmd ${status_cmd} -f ${jobid} 2>/dev/null  | grep job_state | cut -d'=' -f2 | tr -d ' ')"

}


# Job status file writen by remote script:
ssh_max_retries=10
ssh_retry_count=0
status_max_retries=2
status_retry_count=0
export sshcmd=$(echo ${sshcmd} | sed "s|ssh|ssh -o ConnectTimeout=10|g")
while true; do
    sleep 15
    # squeue won't give you status of jobs that are not running or waiting to run
    # qstat returns the status of all recent jobs
    if [[ ${jobschedulertype} == "SLURM" ]]; then
        get_slurm_job_status
        # If job status is empty job is no longer running
        if [ -z "${job_status}" ]; then
            # Test ssh connection to support retries for disconnected clusters
            ${sshcmd} exit
            if [ $? -eq 0 ]; then
                status_retry_count=$((status_retry_count + 1))
                echo "Job status is empty (status attempt ${status_retry_count}/${status_max_retries})"
                if [ $status_retry_count -ge $status_max_retries ]; then
                    job_status=$($sshcmd sacct -j ${jobid}  --format=state | tail -n1)
                    echo "Exiting job status loop"
                    break
                fi
            else
                echo "ERROR: Failed to get SLURM job status using ${sshcmd}"
                echo "       (ssh attempt $((ssh_retry_count + 1))/$ssh_max_retries)"
                ssh_retry_count=$((ssh_retry_count + 1))
            fi
        else
            ssh_retry_count=0
            status_retry_count=0
        fi
    elif [[ ${jobschedulertype} == "PBS" ]]; then
        get_pbs_job_status
        if [[ "${job_status}" == "C" ]]; then
            break
        elif [ -z "${job_status}" ]; then
            # Test ssh connection to support retries for disconnected clusters
            ${sshcmd} exit
            if [ $? -eq 0 ]; then
                break
            else
                echo "ERROR: Failed to get SLURM job status using ${sshcmd}"
                echo "       (ssh attempt $((ssh_retry_count + 1))/$ssh_max_retries)"
                ssh_retry_count=$((ssh_retry_count + 1))
            fi  
        else
            ssh_retry_count=0
            status_retry_count=0
        fi
    fi
    if [ $ssh_retry_count -ge $ssh_max_retries ]; then
        echo "[ $ssh_retry_count -lt $ssh_max_retries ]"
        echo "ERROR: Reached maximum ssh retries for ${sshcmd} command"
        echo "       SSH connection to cluster failed"
        echo "       Exiting workflow"
        exit 2
    fi
done

echo "Job status: ${job_status}"

$sshcmd scontrol show job ${jobid} -dd
$sshcmd sacct -j ${jobid}