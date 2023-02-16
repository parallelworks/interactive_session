echo "$(date): $(hostname):${PWD} $0 $@"

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
    displayErrorMessage "ERROR: File $(hostname):${path_to_sing} not found!"
fi

# WEB ADDRESS ISSUES:
# https://github.com/rstudio/rstudio/issues/7953
# https://support.rstudio.com/hc/en-us/articles/200552326-Running-RStudio-Server-with-a-Proxy


# Generate sha:
if [ -z "${password}" ] || [[ "${password}" == "__""password""__" ]]; then
    echo "No password was specified"
    sha=""
else
    echo "Generating sha"
    sha=$(singularity exec ${path_to_sing} python3 -c "from notebook.auth.security import passwd; print(passwd('__password__', algorithm = 'sha1'))")
fi

# Custom PW plugin:
mkdir -p pw_jupyter_proxy
cat >> pw_jupyter_proxy/__init__.py <<HERE
from tornado.web import StaticFileHandler
from tornado import web
import os
from notebook.utils import url_path_join
import pprint as pp

def load_jupyter_server_extension(nbapp):
    
    print('loading custom plugin')

    web_app = nbapp.web_app
    base_url = web_app.settings['base_url']

    static_path = web_app.settings.get("static_path")
    path_join = url_path_join(base_url, '', 'static', '(.*)')

    web_app.settings['base_url'] = '/me/%s/' % ${openPort}

    # pp.pprint(web_app.settings)

    handlers = [
         (
            path_join,
            StaticFileHandler,
            {'path': os.path.join(static_path[0])}
        )
    ]
    web_app.settings['nbapp'] = nbapp
    web_app.add_handlers('.*', handlers)
HERE


# Served from 
# https://cloud.parallel.works/api/v2/proxy/usercontainer?proxyType=api&proxyTo=/api/v1/display/pw/jobs/57147/service.html
export PYTHONPATH=${PWD}
singularity exec ${gpu_flag} \
    ${mount_dirs} \
    ${path_to_sing} \
    jupyter-notebook \
        --port=${servicePort} \
        --ip=0.0.0.0 \
        --NotebookApp.default_url="/me/${openPort}/tree" \
        --NotebookApp.iopub_data_rate_limit=10000000000 \
        --NotebookApp.token= \
        --NotebookApp.password=$sha \
        --no-browser \
        --notebook-dir=$notebook_dir \
        --NotebookApp.nbserver_extensions "pw_jupyter_proxy=True" \
        --NotebookApp.tornado_settings="{\"static_url_prefix\":\"/me/${openPort}/static/\"}" \
        --NotebookApp.allow_origin=*