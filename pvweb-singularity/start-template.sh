echo "$(date): $(hostname):${PWD} $0 $@"

# FIXME: How do we mount /data?
# MOUNT DIR DEFAULTS
mount_dirs="${mount_dirs} -B ${HOME}:${HOME} -B `pwd`:/data"
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

set -x
singularity run ${gpu_flag} \
    ${mount_dirs} \
    ${service_path_to_sing} \
    /opt/paraview/install/bin/pvpython '"${EXTRA_PVPYTHON_ARGS}"' \
    /opt/paraview/install/share/paraview-5.6/web/visualizer/server/pvw-visualizer.py \
    --content /opt/paraview/install/share/paraview-5.6/web/visualizer/www \
    --port ${service_port} \
    --data /data \
    --viewport-max-width ${service_viewport_max_width} \
    --viewport-max-height ${service_viewport_max_height} \
    --timeout 99999
