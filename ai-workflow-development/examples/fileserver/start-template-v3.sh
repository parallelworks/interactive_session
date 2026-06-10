################################################################################
# fileserver — start service script. No custom code: Python's stdlib http.server
# already does directory listing + downloads. session_runner injects ${service_port}.
#
# NOTE: this exposes the chosen directory READ-ONLY through the session to anyone
# with the session URL. Point it at data you intend to share, not $HOME secrets.
# Inputs (from inputs.sh): fs_dir (directory to serve).
################################################################################
serve_dir="${fs_dir:-$HOME}"
echo "::notice::Serving ${serve_dir} on port ${service_port} from $(hostname)"

echo '#!/bin/bash' > ${PW_PARENT_JOB_DIR}/cancel.sh
chmod +x ${PW_PARENT_JOB_DIR}/cancel.sh

python3 -m http.server "${service_port}" --bind 0.0.0.0 --directory "${serve_dir}" \
    > ${PW_PARENT_JOB_DIR}/fileserver.out 2>&1 &
pid=$!
echo "kill ${pid}" >> ${PW_PARENT_JOB_DIR}/cancel.sh
echo "::notice::http.server started (pid ${pid})"
sleep inf
