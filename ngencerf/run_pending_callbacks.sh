#!/bin/bash
local_data_dir=__LOCAL_DATA_DIR__/slurm-callbacks
pending_callbacks_dir=${local_data_dir}/pending/

# Check if the directory exists
if [ ! -d "${pending_callbacks_dir}" ]; then
    echo "$(date) No pending callbacks found"
    exit 0
fi

echo "$(date) Re-running pending callbacks"

# Sleep some time to give the server time to start up
sleep 120

# Loop through all 'callback' files found under 'pending'
find ${pending_callbacks_dir} -name callback | while read -r callback_path; do
    callback_dir=$(dirname "$callback_path")
    echo "$(date) Checking ${callback_dir} for pending callbacks"


    # Ensure the callback-inputs.sh exists before sourcing
    # - This file is only present if the job already has a status (STARTING, DONE or FAILED). See slurm-wrapper-app-v3.py
    if [[ -f "${callback_dir}/callback-inputs.sh" ]]; then
        source "${callback_dir}/callback-inputs.sh"
    else
        echo "$(date) Warning: ${callback_dir}/callback-inputs.sh not found, skipping."
        continue
    fi
    echo "$(date) Job status is ${job_status}"

    if [[ "${job_status}" == "STARTING" ]]; then
        if ! [[ -f "${callback_dir}/STARTED" ]]; then
            echo "$(date) Starting job callback is pending, resubmitting callback"
            curl -X POST "http://${HOSTNAME}:5000/job-start" \
                -d "job_type=${job_type}" \
                -d "run_id=${run_id}" 
        fi
    else
        if ! [[ -f "${callback_dir}/ENDED" ]]; then
            echo "$(date) Ending job callback is pending, resubmitting callback"
            curl -X POST "http://${HOSTNAME}:5000/postprocess" \
                -d "performance_file=${performance_file}" \
                -d "slurm_job_id=${SLURM_JOB_ID}" \
                -d "job_type=${job_type}" \
                -d "run_id=${run_id}"
        fi
    fi
    sleep 2
done
