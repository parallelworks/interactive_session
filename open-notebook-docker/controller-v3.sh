set -o pipefail

################################################################################
# Interactive Session Controller - Open Notebook
#
# Purpose: Installs NVM and Node.js v22 for the basepath proxy.
#          Docker image pulls happen in start-template-v3.sh on the node
#          where the job actually runs (controller or compute node), because
#          image caches are not shared between nodes.
# Runs on: Controller node
# Called by: Workflow preprocessing step
################################################################################

echo "$(date) INFO: Installing NVM and Node.js v22 for basepath proxy..."
bash "${PW_PARENT_JOB_DIR}/open-notebook-docker/proxy/install.sh"

echo "$(date) INFO: Controller setup complete."
