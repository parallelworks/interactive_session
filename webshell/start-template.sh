# Runs via ssh + sbatch

servicePort="__servicePort__"

cd ~/

screen -wipe
screen -S tty -d -m  ./pworks/ttyd.x86_64 -p $servicePort bash

sleep 9999
