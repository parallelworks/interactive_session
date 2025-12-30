#!/bin/bash
source utils/load-env.sh

if [[ "${use_screen}" == "true" ]]; then
    scp -p ${session_sh} ${resource_publicIp}:${resource_jobdir}/session-${job_number}.sh

    # START STREAMING
    ${sshcmd} touch ${resource_jobdir}/logs.out
    ${sshcmd} tail -f ${resource_jobdir}/logs.out &
    echo "kill \$(ps -x | grep tail | grep ${resource_jobdir}/logs.out | awk '{print \$1}')" >> ${kill_ssh}
    echo "kill $! # kill streaming" >> ${kill_sh}

    # Launch job
    screen_session_name="${workflow_name}-${job_number}"
    echo "Submitting session using screen command"
    $sshcmd "screen -dmS ${screen_session_name} bash -c \"${resource_jobdir}/session-${job_number}.sh > ${resource_jobdir}/logs.out 2>&1\""

    # Prepare cleanup script
    echo "screen -X -S ${screen_session_name} quit" >> ${kill_ssh}

    # Initialize retry counter
    retry_count=0
    max_retries=5
    while true; do
        # Check if the screen session exists on the remote host
        if ssh "${resource_publicIp}" screen -list | grep ${screen_session_name} > /dev/null 2>&1; then
            echo "$(date) ${screen_session_name} screen session is running on ${resource_publicIp}" >> screen-session.log 2>&1
            retry_count=0
        else
            echo "$(date) ${screen_session_name} screen session was not found on ${resource_publicIp}" 2>&1 | tee -a screen-session.log
            retry_count=$((retry_count + 1))
        fi

        # Exit after 5 retries
        if [ "$retry_count" -ge "$max_retries" ]; then
            echo "$(date) Maximum retries reached, exiting." 2>&1 | tee -a screen-session.log
            break
        fi

        sleep 60
    done

else
    echo "Submitting ssh job (wait for node to become available before connecting)..."
    echo "$sshcmd 'bash -s' < ${session_sh}"
    echo
    
    # Run service
    $sshcmd 'bash -s' < ${session_sh} #&> ${pw_job_dir}/session-${job_number}.out
fi
