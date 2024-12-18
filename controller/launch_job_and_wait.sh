#!/bin/bash
source utils/load-env.sh
source resources/host/inputs.sh
source lib.sh

sed -i "s/.*JOB_STATUS.*/    \"JOB_STATUS\": \"Submitted\",/" service.json


if [[ "${use_screen}" == "true" ]]; then

    # Prepare remote directory
    ${sshcmd} mkdir -p ${resource_jobdir}
    scp -p stream.sh ${resource_publicIp}:${resource_jobdir}/stream-${job_number}.sh
    scp -p ${session_sh} ${resource_publicIp}:${resource_jobdir}/session-${job_number}.sh
    
    # Launch job
    screen_session_name="${workflow_name}-${job_number}"
    echo "Submitting session using screen command"
    $sshcmd "screen -dmS ${screen_session_name} bash -c \"${resource_jobdir}/session-${job_number}.sh > ${resource_jobdir}/logs.out 2>&1\""

    # Prepare cleanup script
    echo "screen -X -S ${screen_session_name} quit" >> ${kill_ssh}

    # Stream output
    touch stream.out
    tail -f stream.out &
    tail_pid=$!
    echo "kill ${tail_pid}" >> kill.sh

    #  
    while true; do
        # Check if the screen session exists on the remote host
        if ssh "${resource_publicIp}" screen -list | grep ${screen_session_name} > /dev/null 2>&1; then
            echo "$(date) ${screen_session_name} session is running on ${resource_publicIp}" >> screen-session.log 2>&1
        else
            echo "$(date) ${screen_session_name} session is not running on ${resource_publicIp}" |& tee -a screen-session.log
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

    if [ $? -eq 0 ]; then
        sed -i "s/.*JOB_STATUS.*/    \"JOB_STATUS\": \"Completed\",/" service.json
    else
        sed -i "s/.*JOB_STATUS.*/    \"JOB_STATUS\": \"Failed\",/" service.json
    fi
fi
