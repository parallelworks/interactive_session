################################################################################
# Interactive Session Service Starter - OpenVSCode (code-server)
#
# Purpose: Start code-server web service on allocated port
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - service_port: Allocated port (from session_runner)
#   - service_parent_install_dir: Installation directory
#   - service_download_url: Download URL for code-server
#   - service_password: Access password (optional, auth=none if not set)
#   - service_directory: Working directory to open (default: ~/)
#   - juice_use_juice: Enable Juice for remote GPU access (optional)
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
echo "::notice::Starting code-server: ${juice_cmd} ${service_exec} --bind-addr=0.0.0.0:${service_port} ${password_flag} ${service_directory}"

set -x
pw endpoints run ${pw_endpoints_args} -- ${service_exec} \
    --bind-addr=0.0.0.0:${port} \
    ${gh_flag} \
    ${password_flag} \
    ${service_directory}

if [ $? -ne 0 ]; then
    echo "::error title=Error::code-server command failed"
    exit 1
fi
echo "::endgroup::"