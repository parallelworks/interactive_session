
if [ ! -z "${KUBERNETES_PORT}" ];then
    export USERMODE="k8s"
else
    export USERMODE="docker"
fi


parseArgs() {
    # Exports inputs in the formart
    # --a 1 --b 2 --c --d 4
    # to:
    # export a=1 b=2 c= d=4
    pnames=$(echo ${@} | awk '{ for (i = 1; i <= NF; i++) if (++j % 2 == 1) print $i; }')
    pvals=$(echo ${@} | awk '{ for (i = 1; i <= NF; i++) if (++j % 2 == 0) print $i; }')
    npnames=$(echo ${pnames} | wc -w)
    npvals=$(echo ${pvals}  | wc -w)
    
    if [ ${npnames} -ne ${npvals} ]; then
        echo ERROR: Parameter names and values mismatch! - exiting workflow
	    echo Parameter names:  ${pnames}
	    echo Parameter values: ${pvals}
        exit 1
    fi
    
    for i in $(seq 1 ${npnames}); do
        pname=$(echo ${pnames} | cut -d' ' -f${i} | sed 's/--//' | tr -d \')
        pval=$(echo ${pvals} | cut -d' ' -f${i} | tr -d \')
	echo "export ${pname}=${pval}" >> $(dirname $0)/env.sh
        export "${pname}=${pval}"
    done
}


# get a unique open port
# - try end point
# - if not works --> use random
getOpenPort() {
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


echod() {
    echo $(date): $@
}


replace_templated_inputs() {
    echo Replacing templated inputs
    script=$1
    args=$2

    pnames=$(echo ${args} | awk '{ for (i = 1; i <= NF; i++) if (++j % 2 == 1) print $i; }')
    pvals=$(echo ${args} | awk '{ for (i = 1; i <= NF; i++) if (++j % 2 == 0) print $i; }')
    npnames=$(echo ${pnames} | wc -w)
    npvals=$(echo ${pvals}  | wc -w)
    
    if [ ${npnames} -ne ${npvals} ]; then
        echo ERROR: Parameter names and values mismatch! - exiting workflow
	    echo Parameter names:  ${pnames}
	    echo Parameter values: ${pvals}
        exit 1
    fi
    
    for i in $(seq 1 ${npnames}); do
        pname=$(echo ${pnames} | cut -d' ' -f${i} | sed 's/--//' | tr -d \')
        pval=$(echo ${pvals} | cut -d' ' -f${i} | tr -d \')
        echo "    sed -i \"s|__${pname}__|${pval}|g\" ${script}"
	    sed -i "s|__${pname}__|${pval}|g" ${script}
    done
}


getSchedulerDirectivesFromInputForm() {
    # WARNING: Only works after calling parseArgs
    # Scheduler parameters in the input form are intercepted and formatted here.
    #
    # For example, it transforms arguments:
    # --jobschedulertype slurm --_sch__d_N___ 1 --service jupyter-host --_sch__dd_cpus_d_per_d_task_e_ 1
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
    sch_dnames=$(echo $@ | tr " " "\n" | grep -e '--_sch_' | tr -d \' |  cut -c 3-)
    form_sch_directives=""
    for sch_dname in ${sch_dnames}; do
	    sch_dval=$(env | grep ${sch_dname} | cut -d'=' -f2)
	    sch_dname=$(echo ${sch_dname} | sed "s|_sch_||g" | sed "s|_d_|-|g" | sed "s|_dd_|--|g" | sed "s|_e_|=|g")
        if ! [ -z "${sch_dval}" ] && ! [[ "${sch_dval}" == "default" ]]; then
            form_sched_directives="${form_sched_directives};${sch_dname}${sch_dval}"
        fi
    done
    echo ${form_sched_directives}
}
