#!/bin/bash
source utils/load-env.sh
source resources/host/inputs.sh
set -x

if [ -f "kill.sh" ]; then
    # Only run if file exists. The kill.sh file is moved to _kill.sh after execution.
    # This is done to prevent the file form running twice which would generate errors. 
    bash kill.sh
fi
