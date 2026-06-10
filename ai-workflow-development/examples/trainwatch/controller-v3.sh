################################################################################
# trainwatch — controller script (login node, has internet). Pure-stdlib server,
# so the only requirement is python3. Idempotent.
################################################################################
set -o pipefail
if ! command -v python3 >/dev/null 2>&1; then
    echo "::error title=Error::python3 not found on $(hostname)"
    exit 1
fi
echo "::notice::python3 $(python3 --version 2>&1) on $(hostname)"
