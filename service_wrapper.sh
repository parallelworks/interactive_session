#!/bin/bash

# Exports inputs in the format
# --a 1 --b 2 --c 3
# to:
# export a=1 b=2 c=3
f_read_cmd_args(){
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

echod() {
    echo $(date): $@
}

# Replaces inputs in the format
# --a 1 --b 2 --c 3
# with
# sed -i "s|__a__|1|g" ${script}
# sed -i "s|__b__|2|g" ${script}
# sed -i "s|__c__|3|g" ${script}
replace_templated_inputs() {
    echo Replacing templated inputs
    script=$1
    index=1
    for arg in $@; do
        prefix=$(echo "${arg}" | cut -c1-2)
	    if [[ ${prefix} == '--' ]]; then
	        pname=$(echo $@ | cut -d ' ' -f${index} | sed 's/--//g')
	        pval=$(echo $@ | cut -d ' ' -f$((index + 1)))
	        # To support empty inputs (--a 1 --b --c 3)
	        if [ ${pval:0:2} != "--" ]; then
                echo "    sed -i \"s|__${pname}__|${pval}|g\" ${script}"
		        sed -i "s|__${pname}__|${pval}|g" ${script}
	        fi
	    fi
        index=$((index+1))
    done
}


f_read_cmd_args $@

# SANITY CHECKS
if ! [ -d "${service_name}" ]; then
    echod "ERROR: Directory ${service_name} was not found --> ${service_name} is not supported --> Exiting workflow"
    exit 1
fi

# START / KILL SCRIPTS
if [ -f "${service_name}/start-template.sh" ]; then
    start_service_sh=/pw/jobs/${job_number}/start-service.sh
    cp ${service_name}/start-template.sh ${start_service_sh}
    replace_templated_inputs ${start_service_sh} $@
fi

if [ -f "${service_name}/kill-template.sh" ]; then
    kill_service_sh=/pw/jobs/${job_number}/kill-service.sh
    cp ${service_name}/kill-template.sh ${kill_service_sh}
    replace_templated_inputs ${kill_service_sh} $@
fi

# SERVICE URL
urlend="\""
if [ -f "${service_name}/__URLEND__" ]; then
    urlend=$(cat ${service_name}/__URLEND__)
fi
sed -i "s|__URLEND__|${urlend}|g" service.html.template

bash session_wrapper.sh $@ --start_service_sh ${start_service_sh} --kill_service_sh ${kill_service_sh}
