#!/bin/bash
# Runs the <service-name>/controller.sh script in the controller node which is
# used to install software or run other speficic steps in the controller
source utils/load-env.sh
source resources/host/inputs.sh

set -x

if [ -f "${service_name}/controller-v3.sh" ]; then
    echo; echo; echo "RUNNING PREPROCESSING STEP"
    echo '#!/bin/bash' > controller.sh
    cat resources/host/inputs.sh >> controller.sh
    cat ${service_name}/controller.sh >> controller.sh
    echo "$sshcmd 'bash -s' < controller.sh"
    $sshcmd 'bash -s' < controller.sh
fi
