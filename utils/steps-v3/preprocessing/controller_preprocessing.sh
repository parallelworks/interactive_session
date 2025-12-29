#!/usr/bin/env bash
# set -eo pipefail

# Runs the <service-name>/controller-v3.sh script in the controller node which is
# used to install software or run other speficic steps in the controller
source utils/load-env.sh
source resources/host/inputs.sh

[[ "${DEBUG:-}" == "true" ]] && set -x

if [ -f "${service_name}/controller-v3.sh" ]; then
    echo; echo; echo "RUNNING PREPROCESSING STEP"
    echo '#!/bin/bash' > controller-v3.sh
    cat resources/host/inputs.sh >> controller-v3.sh
    cat ${service_name}/controller-v3.sh >> controller-v3.sh
    echo "$sshcmd 'bash -s' < controller-v3.sh"
    $sshcmd 'bash -s' < controller-v3.sh
fi
