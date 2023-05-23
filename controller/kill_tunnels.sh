# Required at least for servers running in controller node!
KILL_PORTS="__KILL_PORTS__"
for kill_port in ${KILL_PORTS}; do
    tunnel_pid=$(ps -x | grep ssh | grep ${kill_port} | awk '{print $1}')
    if ! [ -z "${tunnel_pid}" ]; then
        echo "Killing tunnel pid ${tunnel_pid} running in ${HOSTNAME}"
        kill ${tunnel_pid}
    fi
done
