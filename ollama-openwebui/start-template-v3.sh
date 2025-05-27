# Runs via ssh + sbatch
set -x

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

if [ -z "${service_nginx_sif}" ]; then
    service_nginx_sif=${service_parent_install_dir}/open-webui.sif
fi

# Initialize cancel script
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh


ollama_port=$(findAvailablePort)

module load ollama
module load singularity

export OLLAMA_MODELS=${service_models}
export OLLAMA_HOST=0.0.0.0:${ollama_port}
export OLLAMA_NUM_PARALLEL=${service_num_parallel}
export OLLAMA_MAX_LOADED_MODELS=${service_max_loaded_models}
export OLLAMA_DEFAULT_KEEP_ALIVE=${service_default_keep_alive}

echo; echo
echo "STARTING OLLAMA SERVER"
ollama serve &
ollama_pid=$!
echo "kill ${ollama_pid} # ollama pid" >> cancel.sh
sleep 5

echo; echo
echo "STARTING OPEN-WEBUI"
mkdir open-webui
echo "{\"version\": 0, \"ui\": {}, \"ollama\": {\"base_urls\": [\"http://0.0.0.0:$ollama_port\"]}}" > open-webui/config.json
singularity exec --bind open-webui:/app/backend/data \
    --env WEBUI_AUTH=False \
    --env OLLAMA_API_BASE_URL=http://0.0.0.0:${ollama_port} \
    --env WEBUI_PORT=${service_port} \
    ${service_nginx_sif} /app/backend/start.sh
