# Exports inputs in the formart
# --a 1 --b 2 --c --d 4
# to:
# export a=1 b=2 d=4
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
	            echo "export ${pname}=${pval}" >> $(dirname $0)/env.sh
	            export "${pname}=${pval}"
		    fi
	    fi
        index=$((index+1))
    done
}

# get a unique open port
getOpenPort() {
    minPort=50000
    maxPort=50100

    qty=1
    count=0
    for i in $(seq $minPort $maxPort); do
        out=$(netstat -aln | grep LISTEN | grep $i)
        if [[ "$out" == "" ]];then
            openPort=$(echo $i)
            (( ++ count ))
        fi
        if [[ "$count" == "$qty" ]];then
            break
        fi
    done
}