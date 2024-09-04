#!/bin/bash
source utils/load-env.sh
source inputs.sh

if [ -z "${workflow_utils_branch}" ]; then
    # If empty, clone the main default branch
    git clone https://github.com/parallelworks/workflow-utils.git
else
    # If not empty, clone the specified branch
    git clone -b "$workflow_utils_branch" https://github.com/parallelworks/workflow-utils.git
fi

mv workflow-utils/* utils
rm -rf workflow-utils

python utils/input_form_resource_wrapper.py

if [ $? -ne 0 ]; then
    displayErrorMessage "ERROR - Resource wrapper failed"
fi

if ! [ -f "resources/host/inputs.sh" ]; then
    displayErrorMessage "ERROR - Missing file ./resources/host/inputs.sh. Resource wrapper failed"
fi
