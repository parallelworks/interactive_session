# RUNS IN THE CONTROLLER NODE:
# - Kill the session script pid and its child processes
job_number=__job_number__
chdir=__chdir__

if ! [ -z ${chdir} ] && ! [[ "${chdir}" == "default" ]]; then
    chdir=$(echo ${chdir} | sed "s|__job_number__|${job_number}|g")
    remote_session_dir=${chdir}
else
    remote_session_dir="./"
fi

job_pid_file=${remote_session_dir}/${job_number}.pid
if [ -f "${job_pid_file}" ]; then
    pid=$(cat ${job_pid_file})
    echo "Killing job=${job_number} pid=${pid}"
    pkill -P ${pid}
    kill ${pid}
    rm ${job_pid_file}
fi