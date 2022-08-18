echo "$(date): $(hostname):${PWD} $0 $@"

mount_dirs="$(echo  __mount_dirs__ | sed "s|___| |g" | sed "s|__mount_dirs__||g" )"
path_to_sing="__path_to_sing__"

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

singularity run \
    --bind run:/run,var-lib-rstudio-server:/var/lib/rstudio-server,database.conf:/etc/rstudio/database.conf \
    ${mount_dirs} \
    ${path_to_sing} \
    /usr/lib/rstudio-server/bin/rserver --www-address=0.0.0.0 --www-port __servicePort__

