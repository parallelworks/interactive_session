#!/bin/bash
source utils/load-env.sh
source resources/host/inputs.sh

set -x

# CREATE KILL FILE:
# - NEEDS TO BE MADE BEFORE RUNNING SESSION SCRIPT!
# - When the job is killed PW runs ${pw_job_dir}/kill.sh

# KILL_SSH: Part of the kill_sh that runs on the remote host with ssh
echo "#!/bin/bash" > ${kill_ssh}
cat resources/host/inputs.sh >> ${kill_ssh} 
if [ -f "${service_name}/kill-template.sh" ]; then
    echo "Adding kill server script ${service_name}/kill-template.sh to ${kill_ssh}"
    cat ${service_name}/kill-template.sh >> ${kill_ssh}
fi
cat utils/kill_session.sh >> ${kill_ssh}


# KILL_SH: File that runs on the user space
job_number_to_clean=$((job_number_int-10))
job_to_clean="/pw/jobs/${workflow_name}/*${job_number_to_clean}"

echo "#!/bin/bash" > ${kill_sh}
echo "mv ${kill_sh} ${kill_sh}.completed" >> ${kill_sh}
cat resources/host/inputs.sh >> ${kill_sh}
#if [ "${job_number_to_clean}" -gt 0 ]; then
#    echo "trap \"rm -rf ${job_to_clean}\" EXIT" >> ${kill_sh}
#fi

echo "echo Running ${kill_sh}" >> ${kill_sh}
# Add kill_ssh
cat >> ${kill_sh} <<HERE
$sshcmd 'bash -s' < ${kill_ssh}
echo Finished running ${kill_sh}
HERE
echo "exit 0" >> ${kill_sh}
chmod 777 ${kill_sh}