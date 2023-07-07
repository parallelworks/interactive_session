if [ ! -z "${KUBERNETES_PORT}" ];then
    export USERMODE="k8s"
else
    export USERMODE="docker"
fi
echo "export USERMODE=${USERMODE}" >> inputs.sh

getOpenPort() {
    minPort=50000
    maxPort=59999

    # Loop until an odd number is found
    while true; do
        openPort=$(curl -s "https://${PARSL_CLIENT_HOST}/api/v2/usercontainer/getSingleOpenPort?minPort=${minPort}&maxPort=${maxPort}&key=${PW_API_KEY}")
        # Check if the number is odd
        if [[ $(($openPort % 2)) -eq 1 ]]; then
            break
        fi
    done
    # Check if openPort variable is a port
    if ! [[ ${openPort} =~ ^[0-9]+$ ]] ; then
        qty=1
        count=0
        for i in $(seq $minPort $maxPort | shuf); do
            out=$(netstat -aln | grep LISTEN | grep $i)
            if [[ "$out" == "" ]] && [[ $(($i % 2)) -eq 1 ]]; then
                    openPort=$(echo $i)
                    (( ++ count ))
            fi
            if [[ "$count" == "$qty" ]];then
                break
            fi
        done
    fi
}


echod() {
    echo $(date): $@
}


displayErrorMessage() {
    echo $(date): $1
    sed -i "s|__ERROR_MESSAGE__|$1|g" error.html
    cp error.html service.html
    sed -i "s/.*ERROR_MESSAGE.*/    \"ERROR_MESSAGE\": \"$1\"/" service.json
    exit 1
}

getSchedulerDirectivesFromInputForm() {
    # WARNING: Only works after sourcing inputs.sh
    # Scheduler parameters in the input form are intercepted and formatted here.
    #
    # For example, it transforms arguments:
    # export host_jobschedulertype=slurm
    # export host__sch__d_N___=1
    # export service=jupyter-host
    # export host__sch__dd_cpus_d_per_d_task_e_=1
    # into:
    # ;-N___1;--cpus-per-task=1
    # Which is then processed out of this function to:
    # # SBATCH -N 1
    # # SBATCH --cpus-per-task=1
    #
    # Character mapping for special scheduler parameters:
    # 1. _sch_ --> ''
    # 1. _d_ --> '-'
    # 2. _dd_ --> '--'
    # 2. _e_ --> '='
    # 3. ___ --> ' ' (Not in this function)
    # Get special scheduler parameters
    sch_inputs=$(env | grep -e '__sch_' | sed 's/.*__sch_//')
    for sch_inp in ${sch_inputs}; do
        sch_dname=$(echo ${sch_inp} | cut -d'=' -f1)
	    sch_dval=$(echo ${sch_inp} | cut -d'=' -f2)
	    sch_dname=$(echo ${sch_dname} | sed "s|_d_|-|g" | sed "s|_dd_|--|g" | sed "s|_e_|=|g")
        if ! [ -z "${sch_dval}" ] && ! [[ "${sch_dval}" == "default" ]]; then
            form_sched_directives="${form_sched_directives};${sch_dname}${sch_dval}"
        fi
    done
    echo ${form_sched_directives}
}

waitForControllerSSH() {
    echo "Checking SSH accesibility to ${host_resource_publicIp}"
    retries=10
    for i in $(seq 1 ${retries}); do
        echo "ssh -o StrictHostKeyChecking=no ${host_resource_publicIp} hostname"
        hname=$(ssh -o StrictHostKeyChecking=no ${host_resource_publicIp} hostname)
        echo "Hostname=${hname}"
        if [ -z ${hname} ]; then
            echo "Waiting for SSH connection"
            # IP address can change and be different from that in inputs.sh!
            export host_resource_publicIp=$(${CONDA_PYTHON_EXE} /swift-pw-bin/utils/cluster-ip-api-wrapper.py ${host_resource_name}.clusters.pw)
        else
            echo "SSH connection is ready"
            echo "export host_resource_publicIp=${host_resource_publicIp}" >> inputs.sh
            return 0
        fi
    done
    displayErrorMessage "ERROR: Failed to establish SSH connection to ${host_resource_publicIp} - Exiting workflow"
    exit 1
}


getRemoteHostInfoFromAPI() {
    # GET HOST INFORMATION FROM API
    # External IP address
    if [ -z ${host_resource_publicIp} ]; then
        export host_resource_publicIp=$(${CONDA_PYTHON_EXE} /swift-pw-bin/utils/cluster-ip-api-wrapper.py ${host_resource_name}.clusters.pw)
    fi

    if [ -z ${host_resource_publicIp} ]; then
        displayErrorMessage "ERROR: host_resource_publicIp variable is empty - Exiting workflow"
        exit 1
    fi

    waitForControllerSSH

    export sshcmd="ssh -o StrictHostKeyChecking=no ${host_resource_publicIp}"
    echo "export sshcmd=\"${sshcmd}\"" >> inputs.sh 

    if [ -z ${host_resource_privateIp} ]; then
        # GET INTERNAL IP OF CONTROLLER NODE. 
        # Get resource definition entry: Empty, internal ip or network name
        export host_resource_privateIp=$(${CONDA_PYTHON_EXE} ${PWD}/utils/pool_api.py ${host_resource_name} internalIp)
        echo "export host_resource_privateIp=${host_resource_privateIp}" >> inputs.sh
    fi

    if [[ "${host_resource_privateIp}" != "" ]] && [[ "${host_resource_privateIp}" != *"."* ]];then
        # If not empty and not an ip --> netowrk name
        host_resource_privateIp=$($sshcmd "ifconfig ${host_resource_privateIp} | sed -En -e 's/.*inet ([0-9.]+).*/\1/p'")
        echo "Using host_resource_privateIp from interface: ${host_resource_privateIp}"
        echo "export host_resource_privateIp=${host_resource_privateIp}" >> inputs.sh
    fi

    if [ -z "${host_resource_privateIp}" ]; then
        # If empty use first internal ip
        export host_resource_privateIp=$($sshcmd hostname -I | cut -d' ' -f1) 
    fi

    if [ -z ${host_resource_privateIp} ]; then
        displayErrorMessage "ERROR: masterIP variable is empty - Exiting workflow"
        echo "Command: $sshcmd hostname -I | cut -d' ' -f1"
        exit 1
    fi

    if [ -z "${host_resource_workdir}" ]; then
        export host_resource_workdir=$(${sshcmd} pwd)
        echo "export host_resource_workdir=${host_resource_workdir}" >> inputs.sh 
    fi

    if [ -z "${host_resource_workdir}" ]; then
        displayErrorMessage "ERROR: Pool workdir not found - exiting the workflow"
        echo "${CONDA_PYTHON_EXE} ${PWD}/utils/pool_api.py ${host_resource_name} workdir"
        exit 1
    fi

}

checkInputParameters() {
    if ! [ -d "${service_name}" ]; then
        displayErrorMessage "ERROR: Directory ${service_name} was not found --> Service ${service_name} is not supported --> Exiting workflow"
        exit 1
    fi

    if ! [ -f "${service_name}/url.sh" ]; then
        displayErrorMessage "ERROR: Directory ${service_name}/url.sh was not found --> Add URL definition script --> Exiting workflow"
        exit 1
    fi

    # GET CONTROLLER IP FROM PW API IF NOT SPECIFIED
    if [ -z "${host_resource_name}" ]; then
        displayErrorMessage "ERROR: No service host was defined - exiting the workflow"
        exit 1
    fi
}