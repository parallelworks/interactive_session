#!/usr/bin/env bash
#
# install.sh - Create the Python environment for this example.
#
# Builds a self-contained Python virtual environment at
#   ${PW_SOFTWARE:-$HOME/pw/software}/fractal-demo
# The example uses only the Python standard library, so no packages are
# downloaded - the environment simply gives the job and the server a consistent,
# isolated Python interpreter that behaves the same on every node.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Where the environment lives. Override PW_SOFTWARE to change the base folder.
PW_SOFTWARE="${PW_SOFTWARE:-$HOME/pw/software}"
VENV_DIR="$PW_SOFTWARE/fractal-demo"
VENV_PYTHON="$VENV_DIR/bin/python"

echo "Setting up the Python environment for the fractal demo."

# 1. Find a Python 3 to build the environment from.
PYTHON="$(command -v python3 || command -v python || true)"
if [ -z "$PYTHON" ]; then
  echo "ERROR: Python 3 was not found on this machine." >&2
  echo "Install Python 3.6 or newer and run ./install.sh again." >&2
  exit 1
fi
if ! "$PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 6) else 1)'; then
  echo "ERROR: Python 3.6 or newer is required. Found: $("$PYTHON" --version 2>&1)" >&2
  exit 1
fi
echo "  Using $("$PYTHON" --version 2>&1) at $PYTHON"

# 2. Create the virtual environment (reuse it if it is already there).
mkdir -p "$PW_SOFTWARE"
if [ -x "$VENV_PYTHON" ]; then
  echo "  Reusing existing environment: $VENV_DIR"
else
  echo "  Creating environment: $VENV_DIR"
  if ! "$PYTHON" -m venv "$VENV_DIR"; then
    echo "ERROR: Could not create the virtual environment." >&2
    echo "Your Python may be missing the 'venv' module. On Debian/Ubuntu run:" >&2
    echo "  sudo apt-get install python3-venv" >&2
    echo "then run ./install.sh again." >&2
    exit 1
  fi
fi

# 3. Confirm it works. This example needs only the standard library, so there
#    are no packages to install.
echo "  Environment Python: $("$VENV_PYTHON" --version 2>&1)"
echo "  No third-party packages are required (standard library only)."

# Make the other scripts executable.
chmod +x "$SCRIPT_DIR/run.sh" "$SCRIPT_DIR/server.sh" 2>/dev/null || true

echo
echo "Install complete. Next steps:"
echo "  1. Start the progress server:   ./server.sh"
echo "  2. Run the job (any terminal):  RESOLUTION=1000 ./run.sh"
