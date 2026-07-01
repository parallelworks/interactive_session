#!/usr/bin/env bash
#
# install.sh - Create the Python environment for this example.
#
# Builds a self-contained Python virtual environment at
#   ${PW_SOFTWARE:-$HOME/pw/software}/fractal-demo
# The example uses only the Python standard library, so no packages are
# downloaded - the environment simply gives the job a consistent, isolated
# Python interpreter that behaves the same on every node.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Where the environment lives. Override PW_SOFTWARE to change the base folder.
PW_SOFTWARE="${PW_SOFTWARE:-$HOME/pw/software}"
VENV_DIR="$PW_SOFTWARE/fractal-demo"
VENV_PYTHON="$VENV_DIR/bin/python"
LOCK_DIR="$PW_SOFTWARE/fractal-demo.lock"

echo "Setting up the Python environment for the fractal demo."

# 0. Serialize installs on this resource. Several workers can land on the same
#    machine at once (matrix fan-out, re-runs), and two `python -m venv` writes
#    into the same directory race and corrupt the environment. A little random
#    jitter spreads out simultaneous starts, then an atomic `mkdir` lock lets
#    exactly one process build the venv while the others wait and reuse it.
mkdir -p "$PW_SOFTWARE"
sleep "$(( RANDOM % 6 ))"

acquired_lock=false
release_lock() { [ "$acquired_lock" = true ] && rmdir "$LOCK_DIR" 2>/dev/null || true; }
trap release_lock EXIT

waited=0
lock_timeout=300
while true; do
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    acquired_lock=true
    break
  fi
  # Another install holds the lock. If it already produced a working venv there
  # is nothing left to do, so reuse it without waiting for the lock.
  if [ -x "$VENV_PYTHON" ]; then
    echo "  Another install already built the environment; reusing $VENV_DIR"
    break
  fi
  if [ "$waited" -ge "$lock_timeout" ]; then
    echo "ERROR: Timed out after ${lock_timeout}s waiting for the install lock $LOCK_DIR." >&2
    echo "If no other install is running, remove it and retry:  rmdir '$LOCK_DIR'" >&2
    exit 1
  fi
  echo "  Waiting for another install on this resource to finish..."
  sleep 5
  waited=$(( waited + 5 ))
done

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

# Make the run script executable.
chmod +x "$SCRIPT_DIR/run.sh" 2>/dev/null || true

echo
echo "Install complete. Next step:"
echo "  Render and serve the fractal:  RESOLUTION=1000 PORT=8000 ./run.sh"
