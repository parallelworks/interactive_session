# Runs in the controller node:
if [[ ${jobschedulertype} == "CONTROLLER" ]]; then
    if [ -f  ${resource_jobdir}/cancel.sh ]; then
        echo "Running ${resource_jobdir}/cancel.sh"
        bash ${resource_jobdir}/cancel.sh
    fi
fi

