# Runs via ssh + sbatch
set -x

# Order of priority for server_exec:
# 1. Whatever is in the ${PATH}
# 2. __server_exec__ (hidden parameter)
# 3. install_paths

server_exec=__server_exec__
partition_or_controller=__partition_or_controller__
install_paths="${HOME}/pworks/*/bin /opt/*/bin /shared/*/bin"

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
service_pid=\$(ps -x | grep openvscode-server | grep ${servicePort} | awk '{print $1}')
HERE


# START SERVICE
if ! [ -z $(which openvscode-server) ]; then
    server_exec=$(which openvscode-server)
elif [ -z ${server_exec} ] || [[ "${server_exec}" == "__""server_exec""__" ]]; then
    server_exec=$(find ${install_paths} -maxdepth 1 -mindepth 1 -name openvscode-server  2>/dev/null | head -n1)
fi

if [ ! -f "${server_exec}" ]; then
    echo ERROR: server_exec=${server_exec} file not found! - Existing workflow!
    exit 1
fi

# https://noaa.parallel.works/pwide-nb/noaa-user-1.parallel.works/50170/notebooks/home/Matthew.Shaxted/Untitled.ipynb?kernel_name=python3

${server_exec} \
    --port ${servicePort} \
    --without-connection-token \
    --host localhost

# Does not work:
#    --host /${FORWARDPATH}/${IPADDRESS}/${openPort}
