#!/bin/bash
source utils/load-env.sh
source resources/host/inputs.sh

set -x

bash ${session_wrapper_dir}/create_session_script.sh 