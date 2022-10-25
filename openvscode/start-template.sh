# Runs via ssh + sbatch
set -x

# Order of priority for server_exec:
# 1. If server server_exec --> Use this
# 2. If not:
#     2.1: If server_exec is in PATH --> Use this
#     2.2: Else --> bootstrap TGZ
#     2.3: Else --> Search in install paths

server_exec=__server_exec__
partition_or_controller=__partition_or_controller__
chdir=__chdir__
job_number=__job_number__
server_dir=__server_dir__
password=__password__
github_token=__github_token__
install_dir=__install_dir__
tgz_path=__tgz_path__

# SET DEFAULTS:
if [ -z ${server_dir} ] || [[ "${server_dir}" == "__""server_dir""__" ]]; then
    server_dir=~/
fi

if [ -z ${github_token} ] || [[ "${github_token}" == "__""github_token""__" ]]; then
    gh_flag=""
else
    export GITHUB_TOKEN=${github_token}
    gh_flag="--github-auth"
fi

if [ -z ${password} ] || [[ "${password}" == "__""password""__" ]]; then
    password_flag="--auth=none"
else
    export PASSWORD=${password}
    password_flag="--auth=password"
fi

if [ -z ${install_dir} ] || [[ "${install_dir}" == "__""install_dir""__" ]]; then
    install_dir=${HOME}/pworks/code-server-4.7.0-linux-amd64
fi

if [ -z ${tgz_path} ] || [[ "${tgz_path}" == "__""tgz_path""__" ]]; then
    tgz_path=/swift-pw-bin/apps/code-server-4.7.0-linux-amd64.tar.gz
fi

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
            if [[ ${partition_or_controller} == "True" ]]; then
                # Running in a compute partition
                if [[ "$USERMODE" == "k8s" ]]; then
                    # HAVE TO DO THIS FOR K8S NETWORKING TO EXPOSE THE PORT
                    # WARNING: Maybe if controller contains user name (user@ip) you need to extract only the ip
                    # Works because home directory is shared!
                    ssh ${ssh_options} $masterIp scp ${USER_CONTAINER_HOST}:${tgz_path} ${install_parent_dir}
                else # Docker mode
                    # Works because home directory is shared!
                    ssh ${ssh_options} $masterIp scp ${USER_CONTAINER_HOST}:${tgz_path} ${install_parent_dir}
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
        bootstrap_tgz ${tgz_path} ${install_dir}
        server_exec=${install_dir}/bin/${server_bin}
    fi

    # Search for the binary in install_paths
    if [ ! -f "${server_exec}" ]; then
        server_exec=$(find ${install_paths} -maxdepth 1 -mindepth 1 -name ${server_bin}  2>/dev/null | head -n1)
    fi
fi

if [ ! -f "${server_exec}" ]; then
    echo ERROR: server_exec=${server_exec} file not found! - Existing workflow!
    exit 1
fi

${server_exec} \
    --bind-addr=localhost:${servicePort} \
    ${gh_flag} \
    ${password_flag} \
    ${server_dir}


exit 0
# For openvscode-server
${server_exec} \
    --port ${servicePort} \
    --without-connection-token \
    --host localhost

