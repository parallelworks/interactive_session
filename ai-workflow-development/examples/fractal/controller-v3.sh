################################################################################
# Fractal demo — controller script
# Runs on: controller/login node (has internet). For resource=workspace it runs
#          directly on the PW workspace.
# Purpose: ensure prerequisites exist. The server is pure-stdlib Python3, so the
#          only requirement is a python3 interpreter — nothing to install.
# Idempotent: safe to re-run.
################################################################################
set -o pipefail

if ! command -v python3 >/dev/null 2>&1; then
    echo "::error title=Error::python3 not found on $(hostname)"
    exit 1
fi

echo "::notice::python3 found: $(python3 --version 2>&1) on $(hostname)"
