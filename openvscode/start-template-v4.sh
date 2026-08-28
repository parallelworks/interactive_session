################################################################################
# Interactive Session Service Starter - OpenVSCode (code-server)
#
# Purpose: Start code-server web service on allocated port
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - pw_endpoints_args: Arguments for pw endpoints run (--name, --slug, ...)
#   - service_parent_install_dir: Installation directory
#   - service_download_url: Download URL for code-server
#   - service_password: Access password (optional, auth=none if not set)
#   - service_directory: Working directory to open (default: ~/)
################################################################################

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

# code-server-4.92.2-linux-amd64.tar.gz
service_tgz_basename=$(echo ${service_download_url} | rev | cut -d'/' -f1 | rev)
# code-server-4.92.2-linux-amd64
service_tgz_stem=$(echo ${service_tgz_basename} | sed "s|.tar.gz||g")

service_tgz_path=${service_parent_install_dir}/${service_tgz_basename}
service_install_dir=${service_parent_install_dir}/${service_tgz_stem}
service_exec=${service_install_dir}/bin/code-server


# SET DEFAULTS:
if [ -z ${service_directory} ]; then
    service_directory=~/
fi

if [ -z ${service_password} ]; then
    password_flag="--auth=none"
else
    export PASSWORD=${service_password}
    password_flag="--auth=password"
fi


# DISABLE EXTENSION TELEMETRY
export VSCODE_TELEMETRY_LEVEL=off
export KILOCODE_POSTHOG_API_KEY=“”
export POSTHOG_DISABLED=1
export POSTHOG_TELEMETRY_ENABLED=false
export ANONYMIZED_TELEMETRY=false
export OTEL_SDK_DISABLED=true
export TELEMETRY_DISABLED=1
export DISABLE_TELEMETRY=1
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export POWERSHELL_TELEMETRY_OPTOUT=1
export NEXT_TELEMETRY_DISABLED=1
export GOTELEMETRY=off

# START SERVICE
echo "::group::Start Service"
echo "::notice::Starting code-server: pw endpoints run ${pw_endpoints_args} -- ${service_exec} --bind-addr=0.0.0.0:{port} ${password_flag} ${service_directory}"

set -x
# {port} is replaced by pw endpoints run with the local port it forwards to
pw endpoints run ${pw_endpoints_args} -- ${service_exec} \
    --bind-addr=0.0.0.0:{port} \
    ${password_flag} \
    ${service_directory}

if [ $? -ne 0 ]; then
    # The pw endpoints command blocks for the life of the service, so it also
    # returns non-zero when the workflow cancels this job after a *successful*
    # launch - which is exactly how wait_for_endpoint releases the run. Treating
    # that as a failure cancelled the whole run from inside the compute job:
    # ollama_gguf runs 24-26 finished "canceled" with the service up, until
    # #1055 disabled this line for that service. Only a launch that never
    # registered its endpoint is a real failure.
    served_name=$(printf '%s' "${pw_endpoints_args}" | sed -n 's/.*--name[ =]\{1,\}\([^ ]*\).*/\1/p')
    if [ -n "${served_name}" ] && pw endpoints list 2>/dev/null | awk '{print $1}' | grep -qxF "${served_name}"; then
        echo "::notice::Endpoint ${served_name} served until this job was cancelled; exiting cleanly"
        exit 0
    fi
    echo "::error title=Error::pw endpoints command failed"
    # Fail loud: without this, wait_for_endpoint polls forever for an endpoint
    # that will never register
    pw workflows runs cancel ${PW_RUN_SLUG}
    exit 1
fi
echo "::endgroup::"