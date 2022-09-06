# Runs via ssh + sbatch
servicePort="__servicePort__"
password="__password__"

echo "Activating conda..."
# FIXME: THIS SHOULD BE AN INPUT!
source __conda_sh__
conda activate __conda_env__
echo "Conda activated"

echo "starting notebook on $servicePort..."

export XDG_RUNTIME_DIR=""

# Generate sha:
echo "Generating sha"
sha=$(python3 -c "from notebook.auth.security import passwd; print(passwd('${password}', algorithm = 'sha1'))")

jupyter-notebook \
    --port=$servicePort \
    --NotebookApp.iopub_data_rate_limit=10000000000 \
    --NotebookApp.token= \
    --NotebookApp.password=$sha \
    --no-browser \
    --notebook-dir=~/ \
    --NotebookApp.tornado_settings="{'static_url_prefix':'/${FORWARDPATH}/${IPADDRESS}/${openPort}/static/'}" \
    --NotebookApp.base_url="/${FORWARDPATH}/${IPADDRESS}/${openPort}/" \
    --NotebookApp.allow_origin=*