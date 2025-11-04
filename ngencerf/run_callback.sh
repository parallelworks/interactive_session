#!/bin/bash
MAX_RETRIES=60 # 1hr
RETRY_COUNT=0
DELAY=60  # seconds between retries

local_data_dir=__LOCAL_DATA_DIR__
callback=$1
job_type=$(basename "$(dirname "$(dirname "$callback")")")
run_id=$(basename "$(dirname "$callback")")
pending_callbacks_run_id_dir=${local_data_dir}/pending/${job_type}/${run_id}
sent_callbacks_dir=${local_data_dir}/sent/${job_type}/

if ! [ -f ${callback} ]; then
    echo "$(date) ERROR: callback file ${callback} does not exist!"
    exit 0
fi

while true; do
    http_code=$(bash ${callback})
    if [[ "${http_code}" != "000" ]]; then
        mkdir -p ${sent_callbacks_dir}
        echo "$(date) HTTP Code is ${http_code}. Moving ${pending_callbacks_run_id_dir} to ${sent_callbacks_dir}"
        mv ${pending_callbacks_run_id_dir} ${sent_callbacks_dir}
        exit 0
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "$(date) HTTP CODE is ${http_code}. Attempt $RETRY_COUNT of $MAX_RETRIES."
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        echo "$(date) Max retries reached. Exiting."
        exit 0
    fi
            
    sleep ${DELAY}
done