#!/bin/bash
# Runs on the remote host

# Inputs:
# --host localhost
# --pushpath pw/path/to/filename
# --pushfile filename
# --delay 30
# --port ${PARSL_CLIENT_SSH_PORT}
# --masterIP internal-IP-of-controller-node

# Exports inputs in the formart
# --a 1 --b 2 --c 3
# to:
# export a=1 b=2 c=3
parseArgs() {
    index=1
    args=""
    for arg in $@; do
	    prefix=$(echo "${arg}" | cut -c1-2)
	    if [[ ${prefix} == '--' ]]; then
	        pname=$(echo $@ | cut -d ' ' -f${index} | sed 's/--//g')
	        pval=$(echo $@ | cut -d ' ' -f$((index + 1)))
		    # To support empty inputs (--a 1 --b --c 3)
		    if [ ${pval:0:2} != "--" ]; then
	            echo "export ${pname}=${pval}" >> $(dirname $0)/stream-env.sh
	            export "${pname}=${pval}"
		    fi
	    fi
        index=$((index+1))
    done
}

parseArgs $@

if [ -z "${port}" ]; then
    port_flag=""
else
    port_flag=" -p ${port} "
fi

sshcmd="ssh ${resource_ssh_usercontainer_options} ${port_flag} $host"

#pushpath=$(ls ${pushpath}*)

${sshcmd} 'cat >>"'$pushpath'"' >> logstream.out 2>&1

while true; do
    if [ -f "$pushfile" ]; then
        echo "Running" >> logstream.out 2>&1
        tail -c +1 -f "$pushfile" | ${sshcmd} 'cat >>"'$pushpath'"' >> logstream.out 2>&1
        echo CLOSING PID: $? >> logstream.out 2>&1
        exit 0
    else
        echo "Preparing" >> logstream.out 2>&1
        echo "preparing inputs" | ${sshcmd} 'cat >>"'$pushpath'"' >> logstream.out 2>&1
        sleep $delay
    fi
done