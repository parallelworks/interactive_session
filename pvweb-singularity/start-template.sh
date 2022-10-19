echo "$(date): $(hostname):${PWD} $0 $@"

path_to_sing="__path_to_sing__"
viewport_max_width="__viewport_max_width__"
viewport_max_height="__viewport_max_height__"

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

set -x
singularity run ${gpu_flag} \
    ${mount_dirs} \
    ${path_to_sing} \
    /opt/paraview/install/bin/pvpython '"${EXTRA_PVPYTHON_ARGS}"' \
    /opt/paraview/install/share/paraview-5.6/web/visualizer/server/pvw-visualizer.py \
    --content /opt/paraview/install/share/paraview-5.6/web/visualizer/www \
    --port ${servicePort} \
    --data /data \
    --viewport-max-width ${viewport_max_width} \
    --viewport-max-height ${viewport_max_height} \
    --timeout 99999