echo "$(date): $(hostname):${PWD} $0 $@"

mount_dirs="$(echo  __mount_dirs__ | sed "s|___| |g" | sed "s|__mount_dirs__||g" )"
path_to_sing="__path_to_sing__"

# MOUNT DIR DEFAULTS
mount_dirs="${mount_dirs} -B ${HOME}:${HOME}"
if [ -d "/contrib" ]; then
    mount_dirs="${mount_dirs} -B /contrib:/contrib"
fi

if [ -d "/lustre" ]; then
    mount_dirs="${mount_dirs} -B /lustre:/lustre"
fi

echo ${mdirs_cmd}

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
singularity run \
    --bind run:/run,var-lib-rstudio-server:/var/lib/rstudio-server,database.conf:/etc/rstudio/database.conf \
    ${mount_dirs} \
    ${path_to_sing} \
    /usr/lib/rstudio-server/bin/rserver \
    --www-address=0.0.0.0 \
    --www-port=__servicePort__  \
    --www-root-path="/${FORWARDPATH}/${IPADDRESS}/${openPort}/" \
    --www-proxy-localhost=0 \
    --auth-none=1 \
    --www-frame-origin=same


