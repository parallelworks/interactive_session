# Runs via ssh + sbatch
set +x

# Order of priority for server_exec:
# 1. Whatever is in the ${PATH}
# 2. __server_exec__ (hidden parameter)
# 3. install_paths

server_exec=__server_exec__
install_paths="${HOME}/pworks/*/bin /opt/*/bin /shared/*/bin"

if ! [ -z $(which openvscode-server) ]; then
    server_exec=$(which openvscode-server)
elif [ -z ${server_exec} ] || [[ "${server_exec}" == "__""server_exec""__" ]]; then
    server_exec=$(find ${install_paths} -maxdepth 1 -mindepth 1 -name openvscode-server | head -n1)
fi

if [ ! -f "${server_exec}" ]; then
    echo ERROR: server_exec=${server_exec} file not found! - Existing workflow!
    exit 1
fi

${server_exec} \
    --port ${servicePort} \
    --without-connection-token \
    --host localhost