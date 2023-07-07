# Required at least for servers running in controller node!
KILL_PORTS="__KILL_PORTS__"
for kill_port in ${KILL_PORTS}; do
    port_pid=$(lsof -i :${kill_port} | grep LISTEN | awk '{print $2}')
    if ! [ -z "${port_pid}" ]; then
        echo "Port ${kill_port}: Killing process ${port_pid} running in ${HOSTNAME}"
        kill ${port_pid}
    fi
done
