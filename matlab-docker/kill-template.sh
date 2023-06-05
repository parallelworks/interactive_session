
{
    bash ${chdir}/docker-kill-${job_number}.sh
    rm ${chdir}/docker-kill-${job_number}.sh
} || {
    echo "ERROR: Could not run bash ${chdir}/docker-kill-${job_number}.sh. Please run it manually!"
}
