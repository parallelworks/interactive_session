echo "$(date): $(hostname):${PWD} $0 $@"

mount_dirs="$(echo  __mount_dirs__ | sed "s|___| |g" | sed "s|__mount_dirs__||g" )"
path_to_sing="__path_to_sing__"

# Bootstrap singularity file if it does not exist
if ! [ -f "${path_to_sing}" ]; then
    echo "WARNING: Path to singularity file <${path_to_sing}> was not found!"
    echo "Trying to build singularity container from definition file ..."
cat >> rserver.def <<HERE
BootStrap: docker
From: centos:centos7

%post
    yum install epel-release -y
    yum install wget -y
    yum install R -y
    wget https://download2.rstudio.org/server/centos7/x86_64/rstudio-server-rhel-1.4.1717-x86_64.rpm
    yum install rstudio-server-rhel-1.4.1717-x86_64.rpm -y

%startscript
    /usr/lib/rstudio-server/bin/rserver

%labels
    Author Alvaro.Vidal
    Version v0.0.1

%help
    This is a container with centos7 and R server
HERE
    sudo singularity build ${path_to_sing} rserver.def
fi

if ! [ -f "${path_to_sing}" ]; then
    # TODO: Copy file from /swift-pw-bin/apps/ ?
    echo "ERROR: Path to singularity file <${path_to_sing}> was not found! --> Exiting workflow"
    exit 1
fi


# MOUNT DIR DEFAULTS
mount_dirs="${mount_dirs} -B ${HOME}:${HOME}"
if [ -d "/contrib" ]; then
    mount_dirs="${mount_dirs} -B /contrib:/contrib"
fi

if [ -d "/lustre" ]; then
    mount_dirs="${mount_dirs} -B /lustre:/lustre"
fi

echo ${mdirs_cmd}

# GPU SUPPORT
if [[ __use_gpus__ == "True" ]]; then
    gpu_flag="--nv"
    # This is only needed in PW clusters
    if [ -d "/usr/share/nvidia/" ]; then
        mount_dirs="${mount_dirs} -B /usr/share/nvidia/:/usr/share/nvidia -B /usr/bin/nvidia-smi:/usr/bin/nvidia-smi"
    fi
else
    gpu_flag=""
fi


# SANITY CHECKS!
if ! [ -f "${path_to_sing}" ]; then
    echo "ERROR: File $(hostname):${path_to_sing} not found!"
    # FIXME: This error is not always streamed back
    sleep 30
    exit 1
fi

# RUN R SERVER
mkdir -p run var-lib-rstudio-server
printf 'provider=sqlite\ndirectory=/var/lib/rstudio-server\n' > database.conf
#singularity exec --bind run:/run,var-lib-rstudio-server:/var/lib/rstudio-server,database.conf:/etc/rstudio/database.conf rserver.sif /usr/lib/rstudio-server/bin/rserver --www-address=127.0.0.1

# WEB ADDRESS ISSUES:
# https://github.com/rstudio/rstudio/issues/7953
# https://support.rstudio.com/hc/en-us/articles/200552326-Running-RStudio-Server-with-a-Proxy

set -x
singularity run ${gpu_flag} \
    --bind run:/run,var-lib-rstudio-server:/var/lib/rstudio-server,database.conf:/etc/rstudio/database.conf \
    ${mount_dirs} \
    ${path_to_sing} \
    /usr/lib/rstudio-server/bin/rserver \
    --www-address=0.0.0.0 \
    --www-port=${servicePort}  \
    --www-root-path="/${FORWARDPATH}/${IPADDRESS}/${openPort}/" \
    --www-proxy-localhost=0 \
    --auth-none=1 \
    --www-frame-origin=same

sleep 99999 # FIXME: Remove


