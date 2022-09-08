# Runs via ssh + sbatch
servicePort=__servicePort__
partition_or_controller=__partition_or_controller__
job_number=__job_number__
slurm_module=__slurm_module__
service_bin=__service_bin__

# Prepare kill service script
# - Needs to be here because we need the hostname of the compute node.
# - kill-template.sh --> service-kill-${job_number}.sh --> service-kill-${job_number}-main.sh

if [[ ${partition_or_controller} == "True" ]]; then
    # Remove .cluster.local for einteinmed!
    hname=$(hostname | sed "s/.cluster.local//g")
    echo "ssh ${hname} 'bash -s' < ${PWD}/service-kill-${job_number}-main.sh" > service-kill-${job_number}.sh
else
    echo "bash ${PWD}/service-kill-${job_number}-main.sh" > service-kill-${job_number}.sh
fi

cat >> service-kill-${job_number}-main.sh <<HERE
service_pid=\$(cat ${PWD}/service.pid)
if [ -z \${service_pid} ]; then
    echo "ERROR: No service pid was found!"
else
    echo "$(hostname) - Killing process: ${service_pid}"
    pkill -P \${service_pid}
    kill \${service_pid}
fi
HERE

#printf "password\npassword\n\n" | vncpasswd

if [ -z $(which vncserver) ]; then
    vncserver_exec=/opt/TurboVNC/bin/vncserver
    if [ -f "${vncserver_exec}" ]; then
        ${vncserver_exec} -kill :1
        ${vncserver_exec} :1
    else
        echo "ERROR: vncserver command not found!"
        exit 1
    fi
else
    vncserver -kill :1
    vncserver :1
fi

job_dir=${PWD}

cd ~/pworks
# if ! [ -d "~/pworks/noVNC-1.3.0" ];then
#     wget https://github.com/novnc/noVNC/archive/refs/tags/v1.3.0.tar.gz
#     tar xzvf v1.3.0.tar.gz
# fi
cd noVNC-1.3.0

# Load slurm module
# - multiple quotes are used to prevent replacement of __varname__ !!!
if ! [ -z ${slurm_module} ] && ! [[ "${slurm_module}" == "__""slurm_module""__" ]]; then
    echo "module load ${slurm_module}"
    module load ${slurm_module}
fi

if [ -z "$(which screen)" ]; then
    ./utils/novnc_proxy --vnc localhost:5901 --listen localhost:${servicePort} &
    echo $! > ${job_dir}/service.pid

    # Launch service
    if ! [ -z ${service_bin} ] && ! [[ "${service_bin}" == "__""service_bin""__" ]]; then
        export DISPLAY=:1
        echo "Starting ${service_bin}"
        ${service_bin} &
        echo $! >> ${job_dir}/service.pid
    fi

else
    screen -S noVNC-${job_number} -d -m ./utils/novnc_proxy --vnc localhost:5901 --listen localhost:${servicePort}
    pid=$(ps -x | grep noVNC-${job_number} | grep -wv grep | awk '{print $1}')
    echo ${pid} > ${job_dir}/service.pid

    # Launch service:
    if ! [ -z ${service_bin} ] && ! [[ "${service_bin}" == "__""service_bin""__" ]]; then
        export DISPLAY=:1
        echo "Starting ${service_bin}"
        screen -S ${service_bin}-${job_number} -d -m ${service_bin}
        pid=$(ps -x | grep ${service_bin}-${job_number} | grep -wv grep | awk '{print $1}')
        echo ${pid} >> ${job_dir}/service.pid
    fi
fi

sleep 99999
