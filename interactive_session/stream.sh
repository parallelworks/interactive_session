#!/bin/bash
# Runs on the remote host

host=$1        # localhost
pushpath="$2"  # pw/path/to/filename
pushfile="$3"  # filename
delay=$4       # 30
port=$5        #

if [ -z "$5" ]; then
    port_flag=""
else
    port_flag=" -p $5 "
fi


if [[ "${host}" == "None" ]]; then
    exit 0
fi

chmod 777 "$PWD" -R


ssh -o StrictHostKeyChecking=no ${port_flag} $host 'cat >"'$pushpath'"' >> logstream.out 2>&1

while true; do
    if [ -f "$pushfile" ]; then
        echo "Running" >> logstream.out 2>&1
        tail -c +1 -f "$pushfile" | ssh -o StrictHostKeyChecking=no ${port_flag} $host 'cat >>"'$pushpath'"' >> logstream.out 2>&1
        echo CLOSING PID: $? >> logstream.out 2>&1
        exit 0
    else
        echo "Preparing" >> logstream.out 2>&1
        echo "preparing inputs" | ssh -o StrictHostKeyChecking=no -p ${port_flag} $host 'cat >>"'$pushpath'"' >> logstream.out 2>&1
        sleep $delay
    fi
done