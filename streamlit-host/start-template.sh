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

if [ -z ${service_streamlit_script} ]; then
    displayErrorMessage "ERROR: No streamlit script was specified!"
elif ! [ -f "${service_streamlit_script}" ]; then
    displayErrorMessage "ERROR: No streamlit script [${service_streamlit_script}] was not found!"
fi

if [[ "${service_conda_install}" == "true" ]]; then
    {
        source ${service_conda_sh}
    } || {
        conda_dir=$(echo ${service_conda_sh} | sed "s|etc/profile.d/conda.sh||g" )
        f_install_miniconda ${conda_dir}
        source ${service_conda_sh}
    }
    {
        conda activate ${service_conda_env}
    } || {
        conda create -n ${service_conda_env} -y
        conda activate ${service_conda_env}
    }
    if [ -z $(which ${jupyter-notebook} 2> /dev/null) ]; then
        conda install -c conda-forge streamlit
    fi
fi

echo "streamlit run ${service_streamlit_script} --server.enableCORS false --server.enableXsrfProtection false --server.port ${openPort}"


sleep 99999
streamlit run ${service_streamlit_script} \
    --server.enableCORS false \
    --server.enableXsrfProtection false \
    --server.port ${openPort}
