# Runs via ssh + sbatch
set -x

password="__password__"
notebook_dir="__notebook_dir__"
CONDA_PATH=$(echo __conda_sh__ | sed "s|etc/profile.d/conda.sh||g")
conda_sh=__conda_sh__
conda_env=__conda_env__
slurm_module=__slurm_module__

CONDA_DIR="$(basename $CONDA_PATH)"
INSTALL_DIR="$(dirname $CONDA_PATH)"

if [ ! -d "$CONDA_PATH" ] && [ "__conda_install__" == "True" ];then
    
    echo "No conda environment found - provisioning miniconda the first time..."
    
    mkdir -p $INSTALL_DIR
    wget -O $INSTALL_DIR/miniconda.sh https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh
    bash $INSTALL_DIR/miniconda.sh -b -p $CONDA_PATH
    rm $INSTALL_DIR/miniconda.sh -f
    
    source $CONDA_PATH/etc/profile.d/conda.sh
    conda activate __conda_env__
    conda install -c anaconda jupyter
    
    echo "Conda now installed..."
    
fi

if ! [ -z "${conda_sh}" ] && ! [[ "${conda_sh}" == "__""conda_sh""__" ]]; then
    source ${conda_sh}
fi

if ! [ -z "${conda_env}" ] && ! [[ "${conda_env}" == "__""conda_env""__" ]]; then
    conda activate ${conda_env}
fi

if ! [ -z "${slurm_module}" ] && ! [[ "${slurm_module}" == "__""slurm_module""__" ]]; then
    module load ${slurm_module}
fi

echo "starting notebook on $servicePort..."

export XDG_RUNTIME_DIR=""

# Generate sha:
if [ -z "${password}" ] || [[ "${password}" == "__""password""__" ]]; then
    echo "No password was specified"
    sha=""
else
    echo "Generating sha"
    sha=$(python3 -c "from notebook.auth.security import passwd; print(passwd('${password}', algorithm = 'sha1'))")
fi
# Set the launch directory for JupyterHub
# If notebook_dir is not set or set to a templated value,
# use the default value of "/".
if [ -z ${notebook_dir} ] || [[ "${notebook_dir}" == "__""notebook_dir""__" ]]; then
    notebook_dir="/"
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

if [[ "$NEW_USERCONTAINER" == "0" ]];then
    # Served from 
    # https://cloud.parallel.works/api/v2/proxy/usercontainer?proxyType=api&proxyTo=/api/v1/display/pw/jobs/57147/service.html
    export PYTHONPATH=${PWD}
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

else
    # Served from:
    # https://noaa.parallel.works /pwide-nb/noaa-user-1.parallel.works/50359/ tree?dt=1670280530105
    # https://cloud.parallel.work /api/v2/proxy/usercontainer?proxyType=api&proxyTo=/api/v1/display/pw/jobs/57147/ service.html
    tornado_settings="{'static_url_prefix':'/${FORWARDPATH}/${IPADDRESS}/${openPort}/static/'}"
    base_url="/${FORWARDPATH}/${IPADDRESS}/${openPort}/"
    jupyter-notebook \
        --port=$servicePort \
        --ip=0.0.0.0 \
        --NotebookApp.iopub_data_rate_limit=10000000000 \
        --NotebookApp.token= \
        --NotebookApp.password=$sha \
        --no-browser \
        --notebook-dir=$notebook_dir \
        --NotebookApp.tornado_settings="{'static_url_prefix':'/${FORWARDPATH}/${IPADDRESS}/${openPort}/static/'}" \
        --NotebookApp.base_url="/${FORWARDPATH}/${IPADDRESS}/${openPort}/" \
        --NotebookApp.allow_origin=*
    
fi

sleep 9999