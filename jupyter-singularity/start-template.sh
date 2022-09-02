echo "$(date): $(hostname):${PWD} $0 $@"

path_to_sing="__path_to_sing__"
servicePort="__servicePort__"
use_gpus="__use_gpus__"

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
if [[ ${use_gpus} == "True" ]]; then
    gpu_flag="--nv"
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

# WEB ADDRESS ISSUES:
# https://github.com/rstudio/rstudio/issues/7953
# https://support.rstudio.com/hc/en-us/articles/200552326-Running-RStudio-Server-with-a-Proxy

# Moving the python3 command to NotebookApp.password= wont work!
sha=$(singularity run ${path_to_sing} python3 -c "from notebook.auth.security import passwd; print(passwd('__password__', algorithm = 'sha1'))")

if [ -z "${sha}" ]; then
    echo "ERROR: No password specified for jupyter notebook - exiting the workflow"
    exit 1
fi

singularity run ${gpu_flag} \
    ${mount_dirs} \
    ${path_to_sing} \
    jupyter-notebook \
    --port=$servicePort \
    --ip=0.0.0.0 \
    --NotebookApp.iopub_data_rate_limit=10000000000 \
    --NotebookApp.token= \
    --NotebookApp.password=${sha} \
    --no-browser \
    --notebook-dir=~/ \
    --NotebookApp.tornado_settings="{'static_url_prefix':'/${FORWARDPATH}/${IPADDRESS}/${openPort}/static/'}" \
    --NotebookApp.base_url="/${FORWARDPATH}/${IPADDRESS}/${openPort}/" \
    --NotebookApp.allow_origin=*

