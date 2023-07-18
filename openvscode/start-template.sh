# Runs via ssh + sbatch
set -x

# Order of priority for server_exec:
# 1. If server server_exec --> Use this
# 2. If not:
#     2.1: If server_exec is in PATH --> Use this
#     2.2: Else --> bootstrap TGZ
#     2.3: Else --> Search in install paths

#server_bin="openvscode-server"
server_bin="code-server"


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

if [ -z ${service_install_dir} ]; then
    service_install_dir=${HOME}/pw/code-server-4.7.0-linux-amd64
fi

if [ -z ${service_tgz_path} ]; then
    service_tgz_path=/swift-pw-bin/apps/code-server-4.7.0-linux-amd64.tar.gz
fi

install_paths="${HOME}/pw/*/bin /opt/*/bin /shared/*/bin"

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
service_pid=\$(ps -x | grep ${server_bin} | grep ${servicePort} | awk '{print \$1}')
kill \${service_pid}
pkill \${service_pid}
HERE


bootstrap_tgz() {
    tgz_path=$1
    install_dir=$2
    # Check if the code directory is present
    # - if not copy from user container -> /swift-pw-bin/noVNC-1.3.0.tgz
    if ! [ -d "${install_dir}" ]; then
        echo "Bootstrapping ${install_dir}"
        install_parent_dir=$(dirname ${install_dir})
        mkdir -p ${install_parent_dir}

        # first check if the noVNC file is available on the node
        if [[ -f "/core/pworks-main/${tgz_path}" ]]; then
            cp /core/pworks-main/${tgz_path} ${install_parent_dir}
        else
            ssh_options="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
            if [[ ${jobschedulertype} != "CONTROLLER" ]]; then
                # Running in a compute partition
                if [[ "$USERMODE" == "k8s" ]]; then
                    # HAVE TO DO THIS FOR K8S NETWORKING TO EXPOSE THE PORT
                    # WARNING: Maybe if controller contains user name (user@ip) you need to extract only the ip
                    # Works because home directory is shared!
                    ssh ${ssh_options} ${resource_privateIp} scp ${USER_CONTAINER_HOST}:${tgz_path} ${install_parent_dir}
                else # Docker mode
                    # Works because home directory is shared!
                    ssh ${ssh_options} ${resource_privateIp} scp ${USER_CONTAINER_HOST}:${tgz_path} ${install_parent_dir}
                fi
            else
                # Running in a controller node
                if [[ "$USERMODE" == "k8s" ]]; then
                    # HAVE TO DO THIS FOR K8S NETWORKING TO EXPOSE THE PORT
                    # WARNING: Maybe if controller contains user name (user@ip) you need to extract only the ip
                    scp ${USER_CONTAINER_HOST}:${tgz_path} ${install_parent_dir}
                else # Docker mode
                    scp ${USER_CONTAINER_HOST}:${tgz_path} ${install_parent_dir}
                fi
            fi
        fi
        tar -zxf ${install_parent_dir}/$(basename ${tgz_path}) -C ${install_parent_dir}
    fi
}


# START SERVICE

if [ -z ${server_exec} ] || [[ "${server_exec}" == "__""server_exec""__" ]]; then
    # If no server_exec is provided
    if ! [ -z $(which ${server_bin}) ]; then
        # If server binary is in the path use it
        server_exec=$(which ${server_bin})
    else
        # Else bootstrap (install) -- Does nothing unless install_dir does not exist
        bootstrap_tgz ${service_tgz_path} ${service_install_dir}
        server_exec=${service_install_dir}/bin/${server_bin}
    fi

    # Search for the binary in install_paths
    if [ ! -f "${server_exec}" ]; then
        server_exec=$(find ${install_paths} -maxdepth 1 -mindepth 1 -name ${server_bin}  2>/dev/null | head -n1)
    fi
fi

if [ ! -f "${server_exec}" ]; then
    displayErrorMessage "ERROR: server_exec=${server_exec} file not found! - Exiting workflow!"
    exit 1
fi

${server_exec} \
    --bind-addr=localhost:${servicePort} \
    ${gh_flag} \
    ${password_flag} \
    ${service_directory}


exit 0
# For openvscode-server
${server_exec} \
    --port ${servicePort} \
    --without-connection-token \
    --host localhost

