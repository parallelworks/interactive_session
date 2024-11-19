#!/bin/bash
source utils/load-env.sh
source resources/host/inputs.sh

bash ${session_wrapper_dir}/launch_job_and_wait.sh 
exit $?
