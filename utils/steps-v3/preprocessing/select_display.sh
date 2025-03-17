#!/bin/bash
kernel_version=$(uname -r | tr '[:upper:]' '[:lower:]')
# Find an available display port
if [[ $kernel_version == *microsoft* ]]; then
    # In windows only this port works
    displayPort=5900
else
    minPort=5901
    maxPort=5999
    for port in $(seq ${minPort} ${maxPort} | shuf); do
        out=$(netstat -aln | grep LISTEN | grep ${port})
        displayNumber=${port: -2}
        XdisplayNumber=$(echo ${displayNumber} | sed 's/^0*//')
        if [ -z "${out}" ] && ! [ -e /tmp/.X11-unix/X${XdisplayNumber} ]; then
            # To prevent multiple users from using the same available port --> Write file to reserve it
            portFile=/tmp/${port}.port.used
            if ! [ -f "${portFile}" ]; then
                touch ${portFile}
                export displayPort=${port}
                export DISPLAY=:${displayNumber#0}
                break
            fi
        fi
    done
fi

echo "export service_port=${displayPort}"
echo "export DISPLAY=${DISPLAY}"
