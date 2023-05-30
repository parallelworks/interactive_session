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
    sch_inputs=$(env | grep -e 'host__sch_' |  cut -c 10-)
    for sch_inp in ${sch_inputs}; do
        sch_dname=$(echo ${sch_inp} | cut -d'=' -f1)
	    sch_dval=$(echo ${sch_inp} | cut -d'=' -f2)
	    sch_dname=$(echo ${sch_dname} | sed "s|host__sch_||g" | sed "s|_d_|-|g" | sed "s|_dd_|--|g" | sed "s|_e_|=|g")
        if ! [ -z "${sch_dval}" ] && ! [[ "${sch_dval}" == "default" ]]; then
            form_sched_directives="${form_sched_directives};${sch_dname}${sch_dval}"
        fi
    done
    echo ${form_sched_directives}
}

getRemoteHostInfoFromAPI() {
    # GET HOST INFORMATION FROM API
    # Pooltype
    pooltype=$(${CONDA_PYTHON_EXE} ${PWD}/utils/pool_api.py ${host_resource_name} type)
    if [ -z "${pooltype}" ]; then
        displayErrorMessage "ERROR: Pool type not found - exiting the workflow"
        echo "${CONDA_PYTHON_EXE} ${PWD}/utils/pool_api.py ${host_resource_name} type"
        exit 1
    fi
    echo "Pool type: ${pooltype}"

    # External IP address
    controller=${host_resource_name}.clusters.pw
    export controller=$(${CONDA_PYTHON_EXE} /swift-pw-bin/utils/cluster-ip-api-wrapper.py $controller)
    export sshcmd="ssh -o StrictHostKeyChecking=no ${controller}"

    # GET INTERNAL IP OF CONTROLLER NODE. 
    # Get resource definition entry: Empty, internal ip or network name
    export masterIp=$(${CONDA_PYTHON_EXE} ${PWD}/utils/pool_api.py ${host_resource_name} internalIp)
    echo "export masterIp=${masterIp}" >> inputs.sh

    if [[ "${masterIp}" != "" ]] && [[ "${masterIp}" != *"."* ]];then
        # If not empty and not an ip --> netowrk name
        masterIp=$($sshcmd "ifconfig ${masterIp} | sed -En -e 's/.*inet ([0-9.]+).*/\1/p'")
        echo "Using masterIp from interface: $masterIp"
    fi

    if [ -z "${masterIp}" ]; then
        # If empty use first internal ip
        export masterIp=$($sshcmd hostname -I | cut -d' ' -f1) 
    fi

    if [ -z ${masterIp} ]; then
        displayErrorMessage "ERROR: masterIP variable is empty - Exitig workflow"
        echo "Command: $sshcmd hostname -I | cut -d' ' -f1"
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

    if [ -z "${host_resource_workdir}" ]; then
        displayErrorMessage "ERROR: Pool workdir not found - exiting the workflow"
        echo "${CONDA_PYTHON_EXE} ${PWD}/utils/pool_api.py ${host_resource_name} workdir"
        exit 1
    fi
}