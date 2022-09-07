# Required at least for servers running in controller node!
tunnel_pid=$(ps -x | grep ssh | grep __OPENPORT__ | awk '{print $1}')
if ! [ -z ${tunnel_pid} ]; then
    echo "Killing tunnel pid ${tunnel_pid} running in ${HOSTNAME}"
    kill ${tunnel_pid}
fi