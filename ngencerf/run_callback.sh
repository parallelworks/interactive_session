#!/bin/bash
MAX_RETRIES=60 # 1hr
RETRY_COUNT=0
DELAY=60  # seconds between retries

local_data_dir=__LOCAL_DATA_DIR__
callback_dir=$1
callback_template=${callback_dir}/callback
callback_inputs=${callback_dir}/callback-inputs.sh

SECONDS=0
while [ ! -f "${callback_inputs}" ] && [ $SECONDS -lt 60 ]; do
    echo "$(date) Waiting for callback input file ${callback_inputs}"
    ls -lat ${callback_dir}
    sleep 1
done

if ! [ -f ${callback_inputs} ]; then
    echo "$(date) ERROR: callback input file ${callback_inputs} does not exist!"
    exit 0
fi
source ${callback_inputs}


pending_callbacks_run_id_dir=${local_data_dir}/slurm-callbacks/pending/${job_type}/${run_id}
completed_callbacks_dir=${local_data_dir}/slurm-callbacks/completed/${job_type}/

echo "$(date) Updating job status to ${job_status}"

if ! [ -f ${callback_template} ]; then
    echo "$(date) ERROR: callback template file ${callback_template} does not exist!"
    exit 0
fi

if [[ "${job_status}" == "STARTING" ]]; then
    if [[ -f "${pending_callbacks_run_id_dir}/STARTED" ]]; then
        echo "$(date) WARNING: Starting callback was already submitted. Exiting..."
        exit 0
    fi
    callback=${pending_callbacks_run_id_dir}/starting-callback
else
    if [[ -f "${pending_callbacks_run_id_dir}/ENDED" ]]; then
        echo "$(date) WARNING: Ending callback was already submitted. Exiting..."
        exit 0
    fi
    callback=${pending_callbacks_run_id_dir}/ending-callback
fi
sed "s|__job_status__|${job_status}|g" ${callback_template} > ${callback}
chmod +x ${callback}

while true; do
    http_code=$(bash ${callback})
    if [[ "${http_code}" != "000" ]]; then
        if [[ "${job_status}" == "STARTING" ]]; then
            touch ${pending_callbacks_run_id_dir}/STARTED
            exit 0
        else
            touch ${pending_callbacks_run_id_dir}/ENDED
            mkdir -p ${completed_callbacks_dir}
            echo "$(date) HTTP Code is ${http_code}. Moving ${pending_callbacks_run_id_dir} to ${completed_callbacks_dir}"
            mv ${pending_callbacks_run_id_dir} ${completed_callbacks_dir}
            exit 0
        fi
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "$(date) HTTP CODE is ${http_code}. Attempt $RETRY_COUNT of $MAX_RETRIES."
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        echo "$(date) Max retries reached. Exiting."
        exit 0
    fi

    sleep ${DELAY}
done