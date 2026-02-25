set -o pipefail

################################################################################
# Interactive Session Controller - Open Notebook
#
# Purpose: Pre-flight validation for Open Notebook Docker deployment
# Runs on: Controller node with internet access
# Called by: Workflow preprocessing step
#
# Docker images are intentionally pulled in start-template-v3.sh on the
# compute/service node, not here. This ensures images are available on the
# node where the containers will actually run.
################################################################################

if ! [ -z ${PW_PARENT_JOB_DIR} ]; then
    cd ${PW_PARENT_JOB_DIR}
fi

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

echo "$(date) INFO: Open Notebook controller check complete."
echo "$(date) INFO: Docker images will be pulled on the service node at startup."
