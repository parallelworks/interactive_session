#!/bin/bash
# Runs the <service-name>/rsync.sh script in the user container to transfer
# files to the controller nodes
source utils/load-env.sh
source resources/host/inputs.sh

set -x

if [ -f "${service_name}/transfer_files.sh" ]; then
    echo; echo; echo "TRASFERRING FILES TO CONTROLLER"
    echo '#!/bin/bash' > transfer_files.sh
    cat resources/host/inputs.sh >> transfer_files.sh
    cat ${service_name}/transfer_files.sh >> transfer_files.sh
    chmod +x transfer_files.sh
    ./transfer_files.sh
fi