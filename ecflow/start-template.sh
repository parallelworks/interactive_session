# Runs via ssh + sbatch

/opt/TurboVNC/bin/vncserver -kill :1
/opt/TurboVNC/bin/vncserver :1

cd ~/pworks
# if ! [ -d "~/pworks/noVNC-1.3.0" ];then
#     wget https://github.com/novnc/noVNC/archive/refs/tags/v1.3.0.tar.gz
#     tar xzvf v1.3.0.tar.gz
# fi
cd noVNC-1.3.0

screen -wipe
screen -S noVNC -d -m ./utils/novnc_proxy --vnc localhost:5901

module load ecflow
export DISPLAY=:1
ecflow_ui

#sleep 9999
