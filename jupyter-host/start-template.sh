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



if [[ "${service_conda_install}" == "true" ]]; then
    {
        source ${service_conda_sh}
    } || {
        conda_dir=$(echo ${service_conda_sh} | sed "s|etc/profile.d/conda.sh||g" )
        f_install_miniconda ${conda_dir}
        source ${service_conda_sh}
    }
    {
        eval "conda activate ${service_conda_env}"
    } || {
        conda create -n ${service_conda_env} jupyter -y
        eval "conda activate ${service_conda_env}"
    }
    if [ -z $(which ${jupyter-notebook} 2> /dev/null) ]; then
        conda install -c anaconda jupyter -y
        conda install nb_conda_kernels -y
        conda install -c anaconda jinja2 -y
    fi
else
    eval "${service_load_env}"
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

jupyter_major_version=$(jupyter notebook --version | cut -d'.' -f1)

echo "Jupyter version is"
jupyter notebook --version 

if [ "${jupyter_major_version}" -lt 7 ]; then

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

else

# Initialize cancel script
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh
jupyterserver_port=$(findAvailablePort)
echo "rm /tmp/${jupyterserver_port}.port.used" >> cancel.sh

#######################
# START NGINX WRAPPER #
#######################

echo "Starting nginx wrapper on service port ${servicePort}"

# Write config file
cat >> config.conf <<HERE
server {
 listen ${servicePort};
 server_name _;
 index index.html index.htm index.php;
 add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
 add_header 'Access-Control-Allow-Headers' 'Authorization,Content-Type,Accept,Origin,User-Agent,DNT,Cache-Control,X-Mx-ReqToken,Keep-Alive,X-Requested-With,If-Modified-Since';
 add_header X-Frame-Options "ALLOWALL";
 location / {
     proxy_pass http://127.0.0.1:${jupyterserver_port}/me/${openPort}/;
     proxy_http_version 1.1;
       proxy_set_header Upgrade \$http_upgrade;
       proxy_set_header Connection "upgrade";
       proxy_set_header X-Real-IP \$remote_addr;
       proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
       proxy_set_header Host \$http_host;
       proxy_set_header X-NginX-Proxy true;
 }
}
HERE

if [ -f "${service_nginx_sif}" ]; then
    echo "Running singularity container ${service_nginx_sif}"
    singularity run --writable-tmpfs  -B $PWD/config.conf:/etc/nginx/conf.d/config.conf nginx-unprivileged.sif &
    echo "kill $!" >> cancel.sh
else
    echo "Running docker container nginx"
    
    container_name="nginx-${servicePort}"
    # Remove container when job is canceled
    echo "sudo docker stop ${container_name}" >> cancel.sh
    echo "sudo docker rm ${container_name}" >> cancel.sh
    # Start container
    sudo service docker start
    sudo docker run  -d --name ${container_name}  -v $PWD/config.conf:/etc/nginx/conf.d/config.conf --network=host nginx
    # Print logs
    sudo docker logs ${container_name}
fi

export JUPYTER_CONFIG_DIR=${PWD}
jupyter notebook --generate-config

##########################
# Do not change anything #
##########################
#  Default: ''
#sed -i "s|^.*c\.ExtensionApp\.default_url.*|c.ExtensionApp.default_url = '/me/${openPort}'|" jupyter_notebook_config.py

#  Default: '/lab'
#sed -i "s|^.*c\.JupyterNotebookApp\.app_url.*|c.JupyterNotebookApp.app_url = '/me/${openPort}/tree'|" jupyter_notebook_config.py

#  Default: '/tree'
#sed -i "s|^.*c\.JupyterNotebookApp\.default_url.*|c.JupyterNotebookApp.default_url = '/me/${openPort}/tree'|" jupyter_notebook_config.py

## Url where the static assets for the extension are served.
#  See also: ExtensionApp.static_url_prefix
#sed -i "s|^.*c\.JupyterNotebookApp\.static_url_prefix.*|c.JupyterNotebookApp.static_url_prefix = '/me/${openPort}/static'|" jupyter_notebook_config.py

## The default URL to redirect to from \`/\`
#  Default: '/'
#sed -i "s|^.*c\.ServerApp\.default_url.*|c.ServerApp.default_url = '/me/${openPort}/'|" jupyter_notebook_config.py

## Supply overrides for the tornado.web.Application that the Jupyter server uses.
#  Default: {}
#c.ServerApp.tornado_settings = {c_ServerApp_tornado_settings}
#sed -i "s|^.*c\.ServerApp\.tornado_settings .*|c.ServerApp.tornado_settings  = {\"static_url_prefix\":\"/me/${openPort}/static/\"}|" jupyter_notebook_config.py

## Whether to trust or not X-Scheme/X-Forwarded-Proto and X-Real-Ip/X-Forwarded-
#  For headerssent by the upstream reverse proxy. Necessary if the proxy handles
#  SSL
#  Default: False
sed -i "s|^.*c\.ServerApp\.trust_xheaders.*|c.ServerApp.trust_xheaders = True|" jupyter_notebook_config.py

## Set the Access-Control-Allow-Origin header
#  
#          Use '*' to allow any origin to access your server.
#  
#          Takes precedence over allow_origin_pat.
#  Default: ''
sed -i "s|^.*c\.ServerApp\.allow_origin\ =.*|c.ServerApp.allow_origin = '\*'|" jupyter_notebook_config.py

## Allow requests where the Host header doesn't point to a local server
#  
#         By default, requests get a 403 forbidden response if the 'Host' header
#         shows that the browser thinks it's on a non-local domain.
#         Setting this option to True disables this check.
#  
#         This protects against 'DNS rebinding' attacks, where a remote web server
#         serves you a page and then changes its DNS to send later requests to a
#         local IP, bypassing same-origin checks.
#  
#         Local IP addresses (such as 127.0.0.1 and ::1) are allowed as local,
#         along with hostnames configured in local_hostnames.
#  Default: False
sed -i "s|^.*c\.ServerApp\.allow_remote_access.*|c.ServerApp.allow_remote_access = True|" jupyter_notebook_config.py


############################
############################

sed -i "s|^.*c\.ServerApp\.token.*|c.ServerApp.token = ''|" jupyter_notebook_config.py

## The base URL for the Jupyter server.
#  
#                         Leading and trailing slashes can be omitted,
#                         and will automatically be added.
#  Default: '/'
# Breaks in combination with the commented ones above
# This one is the only one that sets the base_url when you tunnel to laptop
sed -i "s|^.*c\.ServerApp\.base_url.*|c.ServerApp.base_url = '/me/${openPort}/'|" jupyter_notebook_config.py
#sed -i "s|^.*c\.ServerApp\.base_url.*|c.ServerApp.base_url = '/me/${openPort}/'|" jupyter_notebook_config.py


jupyter-notebook --port=${jupyterserver_port} --no-browser --config=${PWD}/jupyter_notebook_config.py

fi


sleep 9999