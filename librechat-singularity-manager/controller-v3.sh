#!/bin/bash
set -o pipefail
set -x

python3 --version || { echo "::error title=Error::python3 not found in PATH"; exit 1; }

# Install Flask if not already present (installs to ~/.local, shared via NFS to compute nodes)
python3 -c "import flask" 2>/dev/null || python3 -m pip install --quiet flask

python3 -c "import flask; print('flask', flask.__version__)"
echo "::notice::Flask is available"
