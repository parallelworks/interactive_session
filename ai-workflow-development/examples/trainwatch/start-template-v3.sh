################################################################################
# trainwatch — start service script. session_runner injects ${service_port}.
# Binds 0.0.0.0:${service_port}, writes cancel.sh, keeps the job alive.
# Inputs (from inputs.sh): tw_epochs, tw_period (optional).
################################################################################
echo '#!/bin/bash' > ${PW_PARENT_JOB_DIR}/cancel.sh
chmod +x ${PW_PARENT_JOB_DIR}/cancel.sh

python3 ${PW_PARENT_JOB_DIR}/trainwatch/trainwatch_server.py \
    --port "${service_port}" --host 0.0.0.0 \
    --epochs "${tw_epochs:-60}" --period "${tw_period:-0.5}" \
    > ${PW_PARENT_JOB_DIR}/trainwatch.out 2>&1 &
pid=$!
echo "kill ${pid}" >> ${PW_PARENT_JOB_DIR}/cancel.sh
echo "::notice::trainwatch started (pid ${pid}) on ${service_port}"
sleep inf
