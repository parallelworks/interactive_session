#!/bin/bash
set -o pipefail
set -x

python3 --version || { echo "::error title=Error::python3 not found in PATH"; exit 1; }
echo "::notice::Python 3 is available"
