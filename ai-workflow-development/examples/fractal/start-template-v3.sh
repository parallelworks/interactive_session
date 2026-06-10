################################################################################
# Fractal demo — start service script
# Runs on: compute node (scheduler=true) or controller/workspace (scheduler=false)
# Contract with session_runner:
#   - ${service_port} is injected before this script runs; the server MUST bind it
#   - write ${PW_PARENT_JOB_DIR}/cancel.sh so the platform can stop the service
#   - keep the job alive (sleep inf); session_runner's trap runs cancel.sh on cancel
# Inputs (from inputs.sh): mb_width, mb_height, mb_max_iter (all optional)
################################################################################

# Graceful shutdown script consumed by session_runner's cleanup trap.
echo '#!/bin/bash' > ${PW_PARENT_JOB_DIR}/cancel.sh
chmod +x ${PW_PARENT_JOB_DIR}/cancel.sh

# Launch the progressive Mandelbrot server on the allocated port.
python3 ${PW_PARENT_JOB_DIR}/mandelbrot/mandelbrot_server.py \
    --port "${service_port}" \
    --host 0.0.0.0 \
    --width "${mb_width:-480}" \
    --height "${mb_height:-320}" \
    --max-iter "${mb_max_iter:-200}" \
    --out-dir "${PW_PARENT_JOB_DIR}" \
    > ${PW_PARENT_JOB_DIR}/mandelbrot.out 2>&1 &
pid=$!
echo "kill ${pid}" >> ${PW_PARENT_JOB_DIR}/cancel.sh

echo "::notice::Mandelbrot server started (pid ${pid}) on port ${service_port}"

# Keep the job alive; the cleanup trap will run cancel.sh on cancellation.
sleep inf
