# Make sure no conda environment is activated! 
# https://github.com/parallelworks/issues/issues/1081
set -x
# Runs via ssh + sbatch

if [ -z $(which dcv) ]; then
    echo "Installing Nice DCV"
    #################
    # PREREQUISITES #
    #################
    # https://docs.aws.amazon.com/dcv/latest/adminguide/setting-up-installing-linux-prereq.html
    # NICE DCV doesn't support the Wayland protocol. If you're using the GDM3 desktop manager, 
    # you must disable the Wayland protocol. If you aren't using GDM3, skip this step.
    sudo sed -i '/^\[daemon\]$/a WaylandEnable=false' /etc/gdm/custom.conf
    sudo systemctl restart gdm
    # The glxinfo utility provides information about your Linux server's OpenGL configuration
    sudo yum install glx-utils -y

    if nvidia-smi &>/dev/null; then
        # GPU Support
        # Configure the X server to start automatically when the Linux server boots.
        if [[ $(sudo systemctl get-default) == "multi-user.target" ]]; then
            sudo systemctl set-default graphical.target  
        fi
        # Start the X server.
        sudo systemctl isolate graphical.target
        # Verify that the X server is running.
        ps aux | grep X | grep -v grep
        # Generate an updated xorg.conf
        sudo rm -rf /etc/X11/XF86Config*
        #sudo nvidia-xconfig --preserve-busid --enable-all-gpus
        # If you're using a G3 or G4 Amazon EC2 instance and you want to use a multi-monitor console session
        sudo nvidia-xconfig --preserve-busid --enable-all-gpus --connected-monitor=DFP-0,DFP-1,DFP-2,DFP-3
        # Restart the X server for the changes to take effect
        sudo systemctl isolate multi-user.target
        sudo systemctl isolate graphical.target
    else
        # CPU SUPPORT
        # On non-GPU Linux servers: Dummy driver allows the X server to run with a virtual framebuffer when no real GPU is present.
        sudo yum install xorg-x11-drv-dummy -y
        # On non-GPU
        sudo bash -c 'cat >> /etc/X11/xorg.conf <<HERE
cat Section "Device"
Identifier "DummyDevice"
Driver "dummy"
Option "ConstantDPI" "true"
Option "IgnoreEDID" "true"
Option "NoDDC" "true"
VideoRam 2048000
EndSection

Section "Monitor"
    Identifier "DummyMonitor"
    HorizSync   5.0 - 1000.0
    VertRefresh 5.0 - 200.0
    Modeline "1920x1080" 23.53 1920 1952 2040 2072 1080 1106 1108 1135
    Modeline "1600x900" 33.92 1600 1632 1760 1792 900 921 924 946
    Modeline "1440x900" 30.66 1440 1472 1584 1616 900 921 924 946
    ModeLine "1366x768" 72.00 1366 1414 1446 1494  768 771 777 803
    Modeline "1280x800" 24.15 1280 1312 1400 1432 800 819 822 841
    Modeline "1024x768" 18.71 1024 1056 1120 1152 768 786 789 807
EndSection

Section "Screen"
    Identifier "DummyScreen"
    Device "DummyDevice"
    Monitor "DummyMonitor"
    DefaultDepth 24
    SubSection "Display"
        Viewport 0 0
        Depth 24
        Modes "1920x1080" "1600x900" "1440x900" "1366x768" "1280x800" "1024x768"
        virtual 1920 1080
    EndSubSection
EndSection
HERE'
        sudo systemctl isolate multi-user.target
    fi
    # On non-GPU Linux server software rendendering is supported using Mesa drivers
    # On     GPU Linux server software rendendering is supported using NVIDIA drivers
    # To verify that OpenGL software rendering is available: 
    sudo DISPLAY=:0 XAUTHORITY=$(ps aux | grep "X.*\-auth" | grep -v grep | sed -n 's/.*-auth \([^ ]\+\).*/\1/p') glxinfo | grep -i "opengl.*version"

    ###########
    # INSTALL #
    ###########
    sudo rpm --import https://d1uj6qtbmh3dt5.cloudfront.net/NICE-GPG-KEY
    wget https://d1uj6qtbmh3dt5.cloudfront.net/2023.0/Servers/nice-dcv-2023.0-15065-el7-x86_64.tgz
    tar -xvzf nice-dcv-2023.0-15065-el7-x86_64.tgz && cd nice-dcv-2023.0-15065-el7-x86_64
    sudo yum install nice-dcv-server-2023.0.15065-1.el7.x86_64.rpm -y
    sudo yum install nice-dcv-web-viewer-2023.0.15065-1.el7.x86_64.rpm -y
    sudo yum install nice-xdcv-2023.0.547-1.el7.x86_64.rpm -y
    # GPUs
    sudo yum install nice-dcv-gl-2023.0.1027-1.el7.x86_64.rpm -y
    sudo yum install pulseaudio-utils -y

    if [ -z $(which dcv) ]; then
        displayErrorMessage "ERROR: dcv is not installed or not in the PATH - Exiting workflow!"
    fi
fi

if [[ ${service_is_running} == "true" ]]; then
    export DISPLAY=:${service_display}
else
    # Exit workflow if user has an active session
    #     The port is chosen in the /etc/dcv/dcv.conf file and requires
    #     restarting the service to take effect. Therefore, we can't have
    #     two sessions on different ports.
    # FIXME: What if two users of the same cluster want two sessions on the controller node?
    session_list=$(dcv list-sessions)
    if [[ $session_list == *"(owner:${USER}"* ]]; then
        echo "User ${USER} has an active session on ${HOSTNAME}. Exiting workflow."
        exit 0
    fi
    
    #############################
    # CREATE CONFIGURATION FILE #
    #############################
    sudo bash -c "cat > /etc/dcv/dcv.conf <<HERE
[license]
#license-file = \"\"

[log]
#level = \"INFO\"

[session-management]
virtual-session-xdcv-args=\"-listen tcp\"

[session-management/defaults]
#permissions-file = \"\"

[session-management/automatic-console-session]
#owner = \"\"
#permissions-file = \"\"
#max-concurrent-clients = -1
#storage-root = \"\"

[display]
#target-fps = 30

[connectivity]
web-listen-endpoints=['0.0.0.0:${service_port}','[::]:${service_port}']
web-x-frame-options=\"ALLOW-FROM https://0.0.0.0\"
web-extra-http-headers=[(\"Content-Security-Policy\", \"frame-ancestors 'self' https://*\")]
web-port=${service_port}
# web-url-path=\"/me/51533/\"
#enable-quic-frontend=true
#quic-port=8444
#idle-timeout=120

[security]
authentication=\"none\"
#pam-service-name=\"dcv-custom\"
#auth-token-verifier=\"https://127.0.0.1:8444\"

[clipboard]
primary-selection-paste=true
primary-selection-copy=true

HERE"

    #####################
    # STARTING NICE DCV #
    #####################
    # Need to restart after changing the port
    sudo systemctl restart dcvserver
    export DISPLAY=:0
    dcv create-session --storage-root %home% ${job_number}
fi
rm -f ${portFile}

# Prepare kill service script
# - Needs to be here because we need the hostname of the compute node.
# - kill-template.sh --> service-kill-${job_number}.sh --> service-kill-${job_number}-main.sh
echo "Creating file ${resource_jobdir}/service-kill-${job_number}-main.sh from directory ${PWD}"
if [[ ${jobschedulertype} == "CONTROLLER" ]]; then
    echo "bash ${resource_jobdir}/service-kill-${job_number}-main.sh" > ${resource_jobdir}/service-kill-${job_number}.sh
else
    # Remove .cluster.local for einteinmed!
    hname=$(hostname | sed "s/.cluster.local//g")
    echo "ssh ${hname} 'bash -s' < ${resource_jobdir}/service-kill-${job_number}-main.sh" > ${resource_jobdir}/service-kill-${job_number}.sh
fi

cat >> ${resource_jobdir}/service-kill-${job_number}-main.sh <<HERE
service_pid=\$(cat ${resource_jobdir}/service.pid)
if [ -z \${service_pid} ]; then
    echo "ERROR: No service pid was found!"
else
    echo "$(hostname) - Killing process: \${service_pid}"
    for spid in \${service_pid}; do
        pkill -P \${spid}
    done
    kill \${service_pid}
fi
# FIXME: check ~/.dcv to see if there are any logs to print (see turbovnc)
HERE
echo

#if [[ ${service_is_running} != "true" ]]; then
#    dcv close-session ${job_number}
#fi

rm -f ${resource_jobdir}/service.pid
touch ${resource_jobdir}/service.pid

sleep 5 # Need this specially in controller node or second software won't show up!

# Launch service
cd
if ! [ -z "${service_bin}" ] && ! [[ "${service_bin}" == "__""service_bin""__" ]]; then
    if [[ ${service_background} == "False" ]]; then
        echo "Running ${service_bin}"
        ${service_bin}
    else
        echo "Running ${service_bin} in the background"
        ${service_bin} &
        echo $! >> ${resource_jobdir}/service.pid
    fi
fi

# Notify platform that service is running
${sshusercontainer} "${pw_job_dir}/utils/notify.sh Running"

sleep 999999999
