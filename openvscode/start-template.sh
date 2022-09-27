# Runs via ssh + sbatch
set -x

# Order of priority for server_exec:
# 1. Whatever is in the ${PATH}
# 2. __server_exec__ (hidden parameter)
# 3. install_paths

server_exec=__server_exec__
partition_or_controller=__partition_or_controller__
chdir=__chdir__
job_number=__job_number__
server_dir=__server_dir__

install_paths="${HOME}/pworks/*/bin /opt/*/bin /shared/*/bin"
#server_bin="openvscode-server"
server_bin="code-server"

# Prepare kill service script
# - Needs to be here because we need the hostname of the compute node.
# - kill-template.sh --> service-kill-${job_number}.sh --> service-kill-${job_number}-main.sh
echo "Creating file ${chdir}/service-kill-${job_number}-main.sh from directory ${PWD}"
if [[ ${partition_or_controller} == "True" ]]; then
    # Remove .cluster.local for einteinmed!
    hname=$(hostname | sed "s/.cluster.local//g")
    echo "ssh ${hname} 'bash -s' < ${chdir}/service-kill-${job_number}-main.sh" > ${chdir}/service-kill-${job_number}.sh
else
    echo "bash ${chdir}/service-kill-${job_number}-main.sh" > ${chdir}/service-kill-${job_number}.sh
fi

cat >> ${chdir}/service-kill-${job_number}-main.sh <<HERE
service_pid=\$(ps -x | grep ${server_bin} | grep ${servicePort} | awk '{print $1}')
kill \${service_pid}
pkill \${service_pid}
HERE

# SET DEFAULTS:
if [ -z ${server_dir} ] || [[ "${server_dir}" == "__""server_dir""__" ]]; then
    server_dir=~/
fi


# START SERVICE
if ! [ -z $(which ${server_bin}) ]; then
    server_exec=$(which ${server_bin})
elif [ -z ${server_exec} ] || [[ "${server_exec}" == "__""server_exec""__" ]]; then
    server_exec=$(find ${install_paths} -maxdepth 1 -mindepth 1 -name ${server_bin}  2>/dev/null | head -n1)
fi

if [ ! -f "${server_exec}" ]; then
    echo ERROR: server_exec=${server_exec} file not found! - Existing workflow!
    exit 1
fi

${server_exec} \
    --auth=none  \
    --bind-addr=localhost:${servicePort} \
    ${server_dir}


exit 0
# For openvscode-server
${server_exec} \
    --port ${servicePort} \
    --without-connection-token \
    --host localhost

