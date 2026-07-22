################################################################################
# Interactive Session Service Starter - WebShell (ttyd terminal)
#
# Purpose: Start ttyd web terminal behind a pw endpoint
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - pw_endpoints_args: Arguments for pw endpoints run (--name, ...)
#   - service_parent_install_dir: Installation directory
#   - service_novnc_tgz_basename: noVNC tarball (contains ttyd binary)
################################################################################

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

service_novnc_tgz_stem=$(echo ${service_novnc_tgz_basename} | sed "s|.tar.gz||g" | sed "s|.tgz||g")
service_novnc_install_dir=${service_parent_install_dir}/${service_novnc_tgz_stem}

# Attach every browser connection to a shared screen session when screen is
# available, so the terminal survives page reloads; cancel.sh quits it on
# teardown (screen daemonizes itself out of the endpoint's process tree)
if command -v screen >/dev/null 2>&1; then
    screen_name="webshell-${PW_RUN_SLUG}"
    echo "screen -S ${screen_name} -X quit" > cancel.sh
    shell_cmd="cd ${HOME} && { screen -S ${screen_name} -x || screen -S ${screen_name}; }"
else
    shell_cmd="cd ${HOME} && exec bash -l"
fi

echo "::group::Start Service"
echo "::notice::Starting ttyd: pw endpoints run ${pw_endpoints_args} -- ${service_novnc_install_dir}/ttyd.x86_64 -p {port} -s 2 bash -lc \"${shell_cmd}\""

set -x
# {port} is replaced by pw endpoints run with the local port it forwards to
pw endpoints run ${pw_endpoints_args} -- ${service_novnc_install_dir}/ttyd.x86_64 \
    -p {port} -s 2 \
    bash -lc "${shell_cmd}"

if [ $? -ne 0 ]; then
    echo "::error title=Error::pw endpoints command failed"
    # Fail loud: without this, wait_for_endpoint polls forever for an endpoint
    # that will never register
    pw workflows runs cancel ${PW_RUN_SLUG}
    exit 1
fi
echo "::endgroup::"
