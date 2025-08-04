
{
    bash ${resource_jobdir}/docker-kill-${job_number}.sh
    rm ${resource_jobdir}/docker-kill-${job_number}.sh
} || {
    echo "ERROR: Could not run bash ${resource_jobdir}/docker-kill-${job_number}.sh. Please run it manually!"
}
