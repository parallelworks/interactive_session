echo "$(date): $(hostname):${PWD} $0 $@"

job_number=__job_number__
partition_or_controller=__partition_or_controller__

if [[ __use_gpus__ == "True" ]]; then
    gpu_flag="--gpus all"
else
    gpu_flag=""
fi

if [[ ${partition_or_controller} == "True" ]]; then
    # Create kill script. Needs to be here because we need the hostname of the compute node.
    echo ssh "'$(hostname)'" sudo -n docker stop jupyter-$servicePort > docker-kill-${job_number}.sh
else
    echo sudo -n docker stop jupyter-$servicePort > docker-kill-${job_number}.sh
fi

chmod 777 docker-kill-${job_number}.sh

sudo -n systemctl start docker


# Generate sha:
if [ -z "${password}" ] || [[ "${password}" == "__""password""__" ]]; then
    echo "No password was specified"
    sha=""
else
    echo "Generating sha"
    sha=$(sudo -n docker run --rm __docker_repo__ python3 -c "from notebook.auth.security import passwd; print(passwd('__password__', algorithm = 'sha1'))")
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
# https://cloud.parallel.works/api/v2/proxy/usercontainer?proxyType=api&proxyTo=/api/v1/display/${PW_JOB_PATH}/service.html
export PYTHONPATH=${PWD}
sudo -n docker run ${gpu_flag} --rm \
    -v /contrib:/contrib -v /lustre:/lustre -v ${HOME}:${HOME} \
    --name=jupyter-$servicePort \
    -p $servicePort:$servicePort \
    __docker_repo__ jupyter-notebook \
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

sleep 9999

# Docker supports mounting directories that do not exist (singularity does not)
set -x
sudo -n docker run ${gpu_flag} --rm \
    -v /contrib:/contrib -v /lustre:/lustre -v ${HOME}:${HOME} \
    --name=jupyter-$servicePort \
    -p $servicePort:$servicePort \
    __docker_repo__ jupyter-notebook \
    --port=$servicePort \
    --ip=0.0.0.0 \
    --NotebookApp.iopub_data_rate_limit=10000000000 \
    --NotebookApp.token= \
    --NotebookApp.password=${sha} \
    --no-browser \
    --allow-root \
    --notebook-dir=/ \
    --NotebookApp.tornado_settings="${tornado_settings}" \
    --NotebookApp.base_url="${base_url}" \
    --NotebookApp.allow_origin=*