#!/bin/bash
set -e
jobdir=${PWD}
job_number=$(basename ${PWD})

# source the users env file
source ~/.env

echo
echo "JOB NUMBER: ${job_number}"
echo "USER:       ${PW_USER}"
echo "DATE:       $(date)"
echo
# HELPER FUNCTIONS

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

# READ INPUTS
f_read_cmd_args $@

# MANAGE CODE
echo
isession_dir=interactive_session
if [[ "${isession_clone_latest}" == "True" ]]; then
    echo Cloning ${isession_repo_url}
    rm -rf ${isession_dir}
    git clone --recurse-submodules ${isession_repo_url} ${isession_dir}
    git --git-dir=${isession_dir}/.git --work-tree=${isession_dir}/ checkout ${isession_repo_branch}
fi

# MAKE SURE DIRECTORY EXISTS OR PLATFORM WILL CRASH
# https://github.com/parallelworks/issues/issues/323
if [ -d "${isession_dir}" ]; then
    cd ${isession_dir}
else
    echod "ERROR: Directory ${PWD}/${isession_dir} was not found!"
    exit 1
fi

echo
# service_wrapper.sh:
# - Prepares the start and kill service scripts
# - Edits the service.html.tmp with the specific url for the service
# - Executes run_session.sh passing it these scripts as arguments: --start_service_sh --kill_service_sh
echo $@
bash service_wrapper.sh $@ --job_number ${job_number} --isession_dir ${isession_dir}
