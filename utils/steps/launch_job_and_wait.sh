#!/bin/bash
source utils/load-env.sh
source resources/host/inputs.sh

set -x

bash ${session_wrapper_dir}/launch_job_and_wait.sh 