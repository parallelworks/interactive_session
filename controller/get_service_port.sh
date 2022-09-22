#!/bin/bash
servicePort=$1
maxPort=49151 # Last user port

qty=1
count=0
for port in $(seq ${servicePort} ${maxPort}); do
    out=$(netstat -aln | grep LISTEN | grep ${port})
    if [ -z "${out}" ]; then
        echo ${port}
        exit 0
    fi
done