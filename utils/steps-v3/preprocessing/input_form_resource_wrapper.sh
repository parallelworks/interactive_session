#!/bin/bash
source utils/load-env.sh
source inputs.sh

set -x

python ./utils/input_form_resource_wrapper.py

if [ $? -ne 0 ]; then
    displayErrorMessage "ERROR - Resource wrapper failed"
fi

if ! [ -f "resources/host/inputs.sh" ]; then
    displayErrorMessage "ERROR - Missing file ./resources/host/inputs.sh. Resource wrapper failed"
fi
