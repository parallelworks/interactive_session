#!/bin/bash

findAvailablePort() {
    # Find an available availablePort
    minPort=2222
    maxPort=2999
    for port in $(seq ${minPort} ${maxPort} | shuf); do
        out=$(netstat -aln | grep LISTEN | grep ${port})
        if [ -z "${out}" ]; then
            # To prevent multiple users from using the same available port --> Write file to reserve it
            portFile=/tmp/${port}.port.used
            if ! [ -f "${portFile}" ]; then
                touch ${portFile}
                availablePort=${port}
                echo ${port}
                break
            fi
        fi
    done

    if [ -z "${availablePort}" ]; then
        echo "ERROR: No service port found in the range ${minPort}-${maxPort} -- exiting session"
        exit 1
    fi
}

user_container_ssh_port=$(findAvailablePort)

cat > ~/.ssh/config <<HERE
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile=/dev/null
Host usercontainer
    HostName localhost
    User ${USER}
    Port ${user_container_ssh_port}
    StrictHostKeyChecking no

HERE

