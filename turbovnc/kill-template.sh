# Runs in the controller node:

job_number=__job_number__
chdir=__chdir__

if ! [ -z ${chdir} ] && ! [[ "${chdir}" == "default" ]]; then
    chdir=$(echo ${chdir} | sed "s|__job_number__|${job_number}|g")
    remote_session_dir=${chdir}
else
    remote_session_dir="./"
fi

bash ${remote_session_dir}/service-kill-${job_number}.sh

service_pid=$(cat ${remote_session_dir}/service.pid)
if [ -z ${service_pid} ]; then
    echo "ERROR: No service pid was found!"
else
    echo "$(hostname) - Killing process: ${service_pid}"
    pkill -P ${service_pid}
    kill ${service_pid}
fi
