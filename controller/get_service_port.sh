#!/bin/bash

minPort=63029
maxPort=63030
for port in $(seq ${minPort} ${maxPort} | shuf); do
    out=$(netstat -aln | grep LISTEN | grep ${port})
    if [ -z "${out}" ]; then
        # To prevent multiple users from using the same available port --> Write file to reserve it
        portFile=/tmp/${port}.port.used
        if ! [ -f "${portFile}" ]; then
            touch ${portFile}
            export servicePort=${port}
            break
        fi
    fi
done

if [ -z "${servicePort}" ]; then
    echo "ERROR: No service port found in the range ${minPort}-${maxPort} -- exiting session"
    exit 1
fi

echo ${servicePort}