# Runs via ssh + sbatch
set -x

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

# code-server-4.92.2-linux-amd64.tar.gz
service_tgz_basename=$(echo ${service_download_url} | rev | cut -d'/' -f1 | rev)
# code-server-4.92.2-linux-amd64
service_tgz_stem=$(echo ${service_tgz_basename} | sed "s|.tar.gz||g")

service_tgz_path=${service_parent_install_dir}/${service_tgz_basename}
service_install_dir=${service_parent_install_dir}/${service_tgz_stem}
service_exec=${service_install_dir}/bin/code-server


# SET DEFAULTS:
if [ -z ${service_directory} ]; then
    service_directory=~/
fi

if [ -z ${service_github_token} ]; then
    gh_flag=""
else
    export GITHUB_TOKEN=${service_github_token}
    gh_flag="--github-auth"
fi

if [ -z ${service_password} ]; then
    password_flag="--auth=none"
else
    export PASSWORD=${service_password}
    password_flag="--auth=password"
fi

# Prepare kill service script
# - Needs to be here because we need the hostname of the compute node.
# - kill-template.sh --> service-kill-${job_number}.sh --> service-kill-${job_number}-main.sh
echo "Creating file ${resource_jobdir}/service-kill-${job_number}-main.sh from directory ${PWD}"
if [[ ${jobschedulertype} != "CONTROLLER" ]]; then
    # Remove .cluster.local for einteinmed!
    hname=$(hostname | sed "s/.cluster.local//g")
    echo "ssh ${hname} 'bash -s' < ${resource_jobdir}/service-kill-${job_number}-main.sh" > ${resource_jobdir}/service-kill-${job_number}.sh
else
    echo "bash ${resource_jobdir}/service-kill-${job_number}-main.sh" > ${resource_jobdir}/service-kill-${job_number}.sh
fi

cat >> ${resource_jobdir}/service-kill-${job_number}-main.sh <<HERE
service_pid=\$(ps -x | grep ${server_bin} | grep ${service_port} | awk '{print \$1}')
kill \${service_pid}
pkill \${service_pid}
HERE


# START SERVICE
echo ${service_exec} --bind-addr=0.0.0.0:${service_port} ${gh_flag} ${password_flag} ${service_directory}

# Notify platform that service is running
${sshusercontainer} "${pw_job_dir}/utils/notify.sh Running"

${service_exec} \
    --bind-addr=0.0.0.0:${service_port} \
    ${gh_flag} \
    ${password_flag} \
    ${service_directory}

sleep 999999999
# For openvscode-server
${service_exec} \
    --port ${service_port} \
    --without-connection-token \
    --host localhost

