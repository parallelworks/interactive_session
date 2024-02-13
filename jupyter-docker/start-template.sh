# Runs via ssh + sbatch
set -x

# Initialize cancel script
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh

jupyter_container_name="jupyter-${servicePort}"
echo "sudo docker stop ${jupyter_container_name}" >> cancel.sh
echo "sudo docker rm ${jupyter_container_name}" >> cancel.sh

# Set the launch directory for JupyterHub
# If notebook_dir is not set or set to a templated value,
# use the default value of "/".
if [ -z ${service_notebook_dir} ]; then
    service_notebook_dir="/"
fi

sudo service docker start
sudo docker pull ${service_docker_repo}

# Obtain Jupyter version without breaking ssh connection
sudo docker run -i --rm  ${service_docker_repo} jupyter-notebook --version > jupyter.version & 
while [ ! -f "jupyter.version" ]; do
    sleep 2
done
jupyter_major_version=$(cat jupyter.version | tail -n1 | cut -d'.' -f1)

echo "Jupyter version is ${jupyter_major_version}"


#######################
# OLD JUPYTER VERSION #
#######################
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

# Notify platform that service is ready
${sshusercontainer} ${pw_job_dir}/utils/notify.sh

sudo -n docker run ${gpu_flag} -i --rm --name ${jupyter_container_name} \
    ${service_mount_directories} \
    -v ${HOME}:${HOME} \
    -e PYTHONPATH=${PWD} \
    -p ${servicePort}:${servicePort} \
    ${service_docker_repo} \
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
#######################
# NEW JUPYTER VERSION #
#######################

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

container_name="nginx-${servicePort}"
# Remove container when job is canceled
echo "sudo docker stop ${container_name}" >> cancel.sh
echo "sudo docker rm ${container_name}" >> cancel.sh
sudo docker run  -d --name ${container_name}  -v $PWD/config.conf:/etc/nginx/conf.d/config.conf --network=host nginxinc/nginx-unprivileged
# Print logs
sudo docker logs ${container_name}

#########################
# START JUPYTER WRAPPER #
#########################
# Notify platform that service is ready
${sshusercontainer} ${pw_job_dir}/utils/notify.sh

sudo -n docker run ${gpu_flag} -i --rm --name ${jupyter_container_name} \
    ${service_mount_directories} \
    -v ${HOME}:${HOME} \
    -p ${jupyter_port}:${jupyter_port} \
    ${service_docker_repo} \
    jupyter-notebook \
        --port=${jupyter_port} \
        --ip=0.0.0.0 \
        --no-browser  \
        --allow-root \
        --ServerApp.trust_xheaders=True  \
        --ServerApp.allow_origin='*'  \
        --ServerApp.allow_remote_access=True \
        --ServerApp.token=""  \
        --ServerApp.base_url=${BASE_URL} \
        --ServerApp.root_dir=${service_notebook_dir}

fi

sleep 9999
