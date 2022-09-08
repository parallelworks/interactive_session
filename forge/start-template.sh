# Runs via ssh + sbatch
servicePort=__servicePort__
partition_or_controller=__partition_or_controller__
job_number=__job_number__

kill_vnc_cmd="kill \$(ps -x | grep vnc | grep __servicePort__ | awk '{print \$1}')"
if [[ ${partition_or_controller} == "True" ]]; then
    # Create kill script. Needs to be here because we need the hostname of the compute node.
    echo ${kill_vnc_cmd} > kill-vnc-${job_number}-ssh.sh
    # Remove .cluster.local for einteinmed!
    hname=$(hostname | sed "s/.cluster.local//g")
    echo "ssh ${hname} 'bash -s' < ${PWD}/kill-vnc-${job_number}-ssh.sh" > kill-vnc-${job_number}.sh
else
    echo ${kill_vnc_cmd} > kill-vnc-${job_number}.sh
fi

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


cd ~/pworks
# if ! [ -d "~/pworks/noVNC-1.3.0" ];then
#     wget https://github.com/novnc/noVNC/archive/refs/tags/v1.3.0.tar.gz
#     tar xzvf v1.3.0.tar.gz
# fi
cd noVNC-1.3.0

if [ -z "$(which screen)" ]; then
    ./utils/novnc_proxy --vnc localhost:5901 --listen localhost:${servicePort} &
    module load forge
    export DISPLAY=:1
    forge &
else
    screen -S noVNC -d -m ./utils/novnc_proxy --vnc localhost:5901 --listen localhost:${servicePort}
    # ENTER VNC APP SPECIFICS HERE
    module load forge
    export DISPLAY=:1
    screen -S matlab -d -m forge
fi

sleep 99999
