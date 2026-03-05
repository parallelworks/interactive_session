set -o pipefail

################################################################################
# Interactive Session Controller - Open Notebook
#
# Purpose: No controller-side setup required for this service.
#          Docker image pulls happen in start-template-v3.sh on the node
#          where the job actually runs (controller or compute node), because
#          image caches are not shared between nodes.
# Runs on: Controller node
# Called by: Workflow preprocessing step
################################################################################

echo "$(date) INFO: Controller setup complete. No controller-side actions required."
