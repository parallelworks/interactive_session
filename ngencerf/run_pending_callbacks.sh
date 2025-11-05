#!/bin/bash
local_data_dir=__LOCAL_DATA_DIR__
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
    echo "$(date) Re-running ${callback_path}"

    callback_dir=$(dirname "$callback_path")

    # Ensure the postprocess_inputs.sh exists before sourcing
    # - This file is only present if the job already has a status (DONE or FAILED ). See slurm-wrapper-app-v3.py
    if [[ -f "${callback_dir}/postprocess_inputs.sh" ]]; then
        source "${callback_dir}/postprocess_inputs.sh"
    else
        echo "$(date) Warning: ${callback_dir}/postprocess_inputs.sh not found, skipping."
        continue
    fi

    # Perform the POST request
    curl -X POST "http://${HOSTNAME}:5000/postprocess" \
         -d "performance_file=${performance_file}" \
         -d "slurm_job_id=${SLURM_JOB_ID}" \
         -d "job_type=${job_type}" \
         -d "run_id=${run_id}"

    sleep 2
done
