# Runs via ssh + sbatch
servicePort=__servicePort__

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
    screen -wipe
    screen -S noVNC -d -m ./utils/novnc_proxy --vnc localhost:5901 --listen localhost:${servicePort}
    module load forge
    export DISPLAY=:1
    screen -S forge -d -m forge
fi
