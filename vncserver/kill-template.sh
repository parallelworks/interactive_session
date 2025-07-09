# Runs in the controller node:
if [[ ${jobschedulertype} == "CONTROLLER" ]]; then
    echo "Running ${resource_jobdir}/cancel.sh"
    bash ${resource_jobdir}/cancel.sh
else
    compute_node=$(cat ${resource_jobdir}/target.hostname | sed "s/.cluster.local//g")
    # Running the ssh command directly is not working
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${compute_node} ${resource_jobdir}/cancel.sh
fi

