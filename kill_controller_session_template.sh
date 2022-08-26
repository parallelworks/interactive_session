# RUNS IN THE CONTROLLER NODE:
# - Kill the session script pid and its child processes
job_number=__job_number__

job_pid_file=${job_number}.pid
if [ -f "${job_pid_file}" ]; then
    pid=$(cat ${job_pid_file})
    echo "Killing job=${job_number} pid=${pid}"
    pkill -P ${pid}
    kill ${pid}
    rm ${job_pid_file}
fi