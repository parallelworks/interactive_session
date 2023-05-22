
# Runs in the controller node:
if ! [ -z ${chdir} ] && ! [[ "${chdir}" == "default" ]]; then
    chdir=$(echo ${chdir} | sed "s|__job_number__|${job_number}|g")
    remote_session_dir=${chdir}
else
    remote_session_dir="./"
fi

bash ${remote_session_dir}/service-kill-${job_number}.sh

