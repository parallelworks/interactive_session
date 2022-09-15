# Runs via ssh + sbatch
set +x

servicePort="__servicePort__"
password="__password__"

CONDA_PATH="$(echo __conda_sh__)"

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

echo "Activating conda..."
# FIXME: THIS SHOULD BE AN INPUT!
source $CONDA_PATH/etc/profile.d/conda.sh
conda activate __conda_env__
echo "Conda activated"

echo "starting notebook on $servicePort..."

export XDG_RUNTIME_DIR=""

# Generate sha:
echo "Generating sha"
sha=$(python3 -c "from notebook.auth.security import passwd; print(passwd('${password}', algorithm = 'sha1'))")

set -x
jupyter-notebook \
    --port=$servicePort \
    --ip=0.0.0.0 \
    --NotebookApp.iopub_data_rate_limit=10000000000 \
    --NotebookApp.token= \
    --NotebookApp.password=$sha \
    --no-browser \
    --notebook-dir=/ \
    --NotebookApp.tornado_settings="{'static_url_prefix':'/${FORWARDPATH}/${IPADDRESS}/${openPort}/static/'}" \
    --NotebookApp.base_url="/${FORWARDPATH}/${IPADDRESS}/${openPort}/" \
    --NotebookApp.allow_origin=*
