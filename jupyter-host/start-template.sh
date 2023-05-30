# Runs via ssh + sbatch
set -x

f_install_miniconda() {
    install_dir=$1
    echo "Installing Miniconda3-py39_4.9.2"
    conda_repo="https://repo.anaconda.com/miniconda/Miniconda3-py39_4.9.2-Linux-x86_64.sh"
    ID=$(date +%s)-${RANDOM} # This script may run at the same time!
    nohup wget ${conda_repo} -O /tmp/miniconda-${ID}.sh 2>&1 > /tmp/miniconda_wget-${ID}.out
    rm -rf ${install_dir}
    mkdir -p $(dirname ${install_dir})
    nohup bash /tmp/miniconda-${ID}.sh -b -p ${install_dir} 2>&1 > /tmp/miniconda_sh-${ID}.out
}


if ! [ -z "${service_conda_sh}" ]; then
    if [[ "${service_conda_install}" != "True" ]]; then
        source ${service_conda_sh}
        conda activate ${service_conda_env}
    else
        {
            source ${service_conda_sh}
        } || {
            conda_dir=$(echo ${service_conda_sh} | sed "s|etc/profile.d/conda.sh||g" )
            f_install_miniconda ${service_conda_dir}
            source ${service_conda_sh}
        }
        {
            conda activate ${service_conda_env}
        } || {
            conda create -n ${service_conda_env} jupyter -y
            conda activate ${service_conda_env}
        }
        if [ -z $(which ${jupyter-notebook} 2> /dev/null) ]; then
            conda install -c anaconda jupyter -y
        fi
    fi
fi

if ! [ -z "${service_slurm_module}" ]; then
    module load ${service_slurm_module}
fi

echo "starting notebook on $servicePort..."

export XDG_RUNTIME_DIR=""

# Generate sha:
if [ -z "${service_password}" ]; then
    echo "No password was specified"
    sha=""
else
    echo "Generating sha"
    sha=$(python3 -c "from notebook.auth.security import passwd; print(passwd('${service_password}', algorithm = 'sha1'))")
fi
# Set the launch directory for JupyterHub
# If notebook_dir is not set or set to a templated value,
# use the default value of "/".
if [ -z ${service_notebook_dir} ]; then
    service_notebook_dir="/"
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
jupyter-notebook \
    --port=${servicePort} \
    --ip=0.0.0.0 \
    --NotebookApp.default_url="/me/${openPort}/tree" \
    --NotebookApp.iopub_data_rate_limit=10000000000 \
    --NotebookApp.token= \
    --NotebookApp.password=$sha \
    --no-browser \
    --notebook-dir=${service_notebook_dir} \
    --NotebookApp.nbserver_extensions "pw_jupyter_proxy=True" \
    --NotebookApp.tornado_settings="{\"static_url_prefix\":\"/me/${openPort}/static/\"}" \
    --NotebookApp.allow_origin=*



sleep 9999