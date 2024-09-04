echo "$(date): $(hostname):${PWD} $0 $@"

mount_dirs="$(echo  ${service_mount_dirs} | sed "s|___| |g")"

# Bootstrap singularity file if it does not exist
if ! [ -f "${service_path_to_sing}" ]; then
    echo "WARNING: Path to singularity file <${service_path_to_sing}> was not found!"
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
    sudo -n singularity build ${service_path_to_sing} rserver.def
fi

if ! [ -f "${service_path_to_sing}" ]; then
    # TODO: Copy file from /swift-pw-bin/apps/ ?
    displayErrorMessage "ERROR: Path to singularity file <${service_path_to_sing}> was not found! --> Exiting workflow"
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
if [[ ${service_use_gpus} == "true" ]]; then
    gpu_flag="--nv"
    # This is only needed in PW clusters
    if [ -d "/usr/share/nvidia/" ]; then
        mount_dirs="${mount_dirs} -B /usr/share/nvidia/:/usr/share/nvidia -B /usr/bin/nvidia-smi:/usr/bin/nvidia-smi"
    fi
else
    gpu_flag=""
fi


# SANITY CHECKS!
if ! [ -f "${service_path_to_sing}" ]; then
    displayErrorMessage "ERROR: File $(hostname):${service_path_to_sing} not found!"
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
    ${service_path_to_sing} \
    /usr/lib/rstudio-server/bin/rserver \
    --www-address=0.0.0.0 \
    --www-port=${service_port}  \
    --www-proxy-localhost=0 \
    --auth-none=1 \
    --www-frame-origin=same


