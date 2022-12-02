# WRITE SLURM DIRECTIVES IN SBATCH HEADER

if ! [ -z ${partition} ] && ! [[ "${partition}" == "default" ]]; then
    echo "#SBATCH --partition=${partition}" >> ${session_sh}
fi

if ! [ -z ${account} ] && ! [[ "${account}" == "default" ]]; then
    echo "#SBATCH --account=${account}" >> ${session_sh}
fi

if ! [ -z ${walltime} ] && ! [[ "${walltime}" == "default" ]]; then
    echo "#SBATCH --time=${walltime}" >> ${session_sh}
fi

if ! [ -z ${chdir} ] && ! [[ "${chdir}" == "default" ]]; then
    echo "#SBATCH --chdir=${chdir}" >> ${session_sh}
fi

if [ -z ${numnodes} ]; then
    echo "#SBATCH --nodes=1" >> ${session_sh}
else
    echo "#SBATCH --nodes=${numnodes}" >> ${session_sh}
fi

if [[ "${exclusive}" == "True" ]]; then
    echo "#SBATCH --exclusive" >> ${session_sh}
fi

if ! [ -z ${cpus_per_task} ]; then
    echo "#SBATCH --cpus-per-task=${cpus_per_task}" >> ${session_sh}
fi

echo "#SBATCH --job-name=session-${job_number}" >> ${session_sh}
echo "#SBATCH --output=session-${job_number}.out" >> ${session_sh}

if ! [ -z ${custom_directives} ]; then
    for cusdir in $(echo ${custom_directives} | sed "s|;| |g"); do
        echo "#SBATCH ${cusdir}" >> ${session_sh}
    done
fi
