# Make sure no conda environment is activated! 
# https://github.com/parallelworks/issues/issues/1081
export $(env | grep CONDA_PREFIX)
echo ${CONDA_PREFIX}

if ! [ -z "${CONDA_PREFIX}" ]; then
    echo "Deactivating conda environment"
    source ${CONDA_PREFIX}/etc/profile.d/conda.sh
    conda deactivate
fi


set -x
# Runs via ssh + sbatch
partition_or_controller=__partition_or_controller__
job_number=__job_number__
slurm_module=__slurm_module__
service_bin="$(echo __service_bin__  | sed "s|---| |g" | sed "s|___| |g")"
service_background=__service_background__ # Launch service as a background process
chdir=__chdir__

if [ -z $(which dcv) ]; then
    echo "Installing Nice DCV"
    #####################
    # CPU PREREQUISITES #
    #####################
    # NICE DCV doesn't support the Wayland protocol. If you're using the GDM3 desktop manager, 
    # you must disable the Wayland protocol. If you aren't using GDM3, skip this step.
    sudo sed -i '/^\[daemon\]$/a WaylandEnable=false' /etc/gdm/custom.conf
    sudo systemctl restart gdm
    
    # The glxinfo utility provides information about your Linux server's OpenGL configuration
    sudo yum install glx-utils -y

    # On non-GPU Linux server software rendendering is supported using Mesa drivers
    # To verify that OpenGL software rendering is available: 
    sudo DISPLAY=:0 XAUTHORITY=$(ps aux | grep "X.*\-auth" | grep -v grep | sed -n 's/.*-auth \([^ ]\+\).*/\1/p') glxinfo | grep -i "opengl.*version"
    sudo yum install xorg-x11-drv-dummy -y
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
    
    ###############
    # CPU INSTALL #
    ###############
    sudo rpm --import https://d1uj6qtbmh3dt5.cloudfront.net/NICE-GPG-KEY
    wget https://d1uj6qtbmh3dt5.cloudfront.net/2023.0/Servers/nice-dcv-2023.0-15065-el7-x86_64.tgz
    tar -xvzf nice-dcv-2023.0-15065-el7-x86_64.tgz && cd nice-dcv-2023.0-15065-el7-x86_64
    sudo yum install nice-dcv-server-2023.0.15065-1.el7.x86_64.rpm -y
    sudo yum install nice-dcv-web-viewer-2023.0.15065-1.el7.x86_64.rpm -y
    sudo yum install nice-xdcv-2023.0.547-1.el7.x86_64.rpm -y
    # GPUs
    # sudo yum install nice-dcv-gl-2023.0.1027-1.el7.x86_64.rpm
    sudo yum install pulseaudio-utils -y
    
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
web-listen-endpoints=['0.0.0.0:${servicePort}','[::]:${servicePort}']
web-x-frame-options=\"ALLOW-FROM https://0.0.0.0\"
web-extra-http-headers=[(\"Content-Security-Policy\", \"frame-ancestors 'self' https://*\")]
web-port=${servicePort}
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
    if [ -z $(which dcv) ]; then
        displayErrorMessage "ERROR: dcv is not installed or not in the PATH - Exiting workflow!"
    fi
fi

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

#####################
# STARTING NICE DCV #
#####################
# Need to restart after changing the port
sudo systemctl restart dcvserver
dcv create-session --storage-root %home% ${job_number}
rm -f ${portFile}

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
service_pid=\$(cat ${chdir}/service.pid)
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
dcv close-session ${job_number}
HERE
echo

rm -f ${chdir}/service.pid
touch ${chdir}/service.pid

echo
# Load slurm module
# - multiple quotes are used to prevent replacement of __varname__ !!!
if ! [ -z ${slurm_module} ] && ! [[ "${slurm_module}" == "__""slurm_module""__" ]]; then
    echo "module load ${slurm_module}"
    module avail ${slurm_module}
    module load ${slurm_module}
fi
echo

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
        echo $! >> ${chdir}/service.pid
    fi
fi
    
sleep 99999
