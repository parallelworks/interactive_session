# WRITE SLURM DIRECTIVES IN SBATCH HEADER

if ! [ -z ${partition} ] && ! [[ "${partition}" == "default" ]]; then
    echo "#PBS -q ${partition}" >> ${session_sh}
fi

if ! [ -z ${account} ] && ! [[ "${account}" == "default" ]]; then
    echo "#PBS -A ${account}" >> ${session_sh}
fi

if ! [ -z ${walltime} ] && ! [[ "${walltime}" == "default" ]]; then
    echo "#PBS -l walltime=${walltime}" >> ${session_sh}
fi

if [ -z ${numnodes} ]; then
    resources_allocated="nodes=${numnodes}"
else
    resources_allocated="nodes=1"
fi

if ! [ -z ${processors_per_node} ]; then
    resources_allocated="${resources_allocated}:ppn=${processors_per_node}"
fi

echo "#PBS -l ${resources_allocated}" >> ${session_sh}

if [[ "${exclusive}" == "True" ]]; then
    echo "#PBS -l naccesspolicy=SINGLEJOB -n" >> ${session_sh}
fi

echo "#PBS -N session-${job_number}" >> ${session_sh}

# Have not found a PBS equivalent to SLURM chdir directive
if ! [ -z ${chdir} ] && ! [[ "${chdir}" == "default" ]]; then
    echo "#PBS -o=${chdir}/session-${job_number}.out" >> ${session_sh}
else
    echo "#PBS -o=session-${job_number}.out" >> ${session_sh}
fi 

# Redirect standard error "e" to standard output "o"
echo "#PBS -j oe" >> ${session_sh}
