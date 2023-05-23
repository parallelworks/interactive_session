if [ ! -z "${KUBERNETES_PORT}" ];then
    export USERMODE="k8s"
else
    export USERMODE="docker"
fi
echo "export USERMODE=${USERMODE}" >> inputs.sh


# get a unique open port
# - try end point
# - if not works --> use random
# Original getOpenPort function. Was replaced because only odd ports work in emed
getOpenPort_() {
    minPort=50000
    maxPort=59999

    openPort=$(curl -s "https://${PARSL_CLIENT_HOST}/api/v2/usercontainer/getSingleOpenPort?minPort=${minPort}&maxPort=${maxPort}&key=${PW_API_KEY}")
    # Check if openPort variable is a port
    if ! [[ ${openPort} =~ ^[0-9]+$ ]] ; then
        qty=1
        count=0
        for i in $(seq $minPort $maxPort | shuf); do
            out=$(netstat -aln | grep LISTEN | grep $i)
            if [[ "$out" == "" ]];then
                openPort=$(echo $i)
                (( ++ count ))
            fi
            if [[ "$count" == "$qty" ]];then
                break
            fi
        done
    fi
}

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

replace_templated_inputs() {
    echo Replacing templated inputs
    script=$1
    index=1
    for arg in $@; do
        prefix=$(echo "${arg}" | cut -c1-6)
	    if [[ ${prefix} == '--' ]]; then
	        pname=$(echo $@ | cut -d ' ' -f${index} | sed 's/--//g')
	        pval=$(echo $@ | cut -d ' ' -f$((index + 1)))
	        # To support empty inputs (--a 1 --b --c 3)
	        if [ ${pval:0:6} != "--" ]; then
                echo "    sed -i \"s|__${pname}__|${pval}|g\" ${script}"
		        sed -i "s|__${pname}__|${pval}|g" ${script}
	        else
                echo "    sed -i \"s|__${pname}__||g\" ${script}"
                sed -i "s|__${pname}__||g" ${script}		    
		    fi
	    fi
        index=$((index+1))
    done
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
    echo ${sch_inputs}
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
