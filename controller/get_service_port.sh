#!/bin/bash
servicePort=$1
maxPort=49151 # Last user port

qty=1
count=0
for port in $(seq ${servicePort} ${maxPort}); do
    out=$(netstat -aln | grep LISTEN | grep ${port})
    if [ -z "${out}" ]; then
        # To prevent multiple users from using the same available port --> Write file to reserve it
        portFile=/tmp/${port}.port.used
        if ! [ -f "${portFile}" ]; then
            touch ${portFile}
            echo ${port}
            exit 0
        fi
    fi
done