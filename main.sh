#!/bin/bash

# Define a cleanup function
cleanup() {
    ./utils/steps/clean_and_exit.sh 2>&1 | tee clean_and_exit.out
}

# Set the trap to call cleanup on script exit
trap cleanup EXIT


./utils/steps/preprocessing.sh 2>&1 | tee preprocessing.out || exit 1
./utils/steps/input_form_resource_wrapper.sh 2>&1 | tee input_form_resource_wrapper.out || exit 1
./utils/steps/process_inputs_sh.sh 2>&1 | tee process_inputs_sh.out || exit 1
./utils/steps/controller_preprocessing.sh 2>&1 | tee controller_preprocessing.out || exit 1
./utils/steps/prepare_service_json.sh 2>&1 | tee prepare_service_json.out || exit 1
./utils/steps/initialize_cancel_script.sh 2>&1 | tee initialize_cancel_script.out || exit 1
./utils/steps/create_session_script.sh 2>&1 | tee create_session_script.out || exit 1
./utils/steps/launch_job_and_wait.sh 2>&1 | tee launch_job_and_wait.out || exit 1