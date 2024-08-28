#service_download_url="https://github.com/coder/code-server/releases/download/v4.92.2/code-server-4.92.2-linux-amd64.tar.gz"

# The URL downloads a different file when using wget/curl than when pasting it in the browser
# service_copilot_url="https://marketplace.visualstudio.com/_apis/public/gallery/publishers/GitHub/vsextensions/copilot/latest/vspackage"
service_copilot_usercontainer_path="${PW_JOB_PATH}/${service_name}/GitHub.copilot-latest.vsix"

sshusercontainer="ssh ${resource_ssh_usercontainer_options_controller} -f ${USER_CONTAINER_HOST}"

displayErrorMessage() {
    echo $(date): $1
    ${sshusercontainer} "sed -i \"s|.*ERROR_MESSAGE.*|    \\\"ERROR_MESSAGE\\\": \\\"$1\\\"|\" ${PW_JOB_PATH}/service.json"
    ${sshusercontainer} "sed -i \"s|.*JOB_STATUS.*|    \\\"JOB_STATUS\\\": \\\"FAILED\\\",|\" ${PW_JOB_PATH}/service.json"
}


init_code_server_settings() {
    local settings_dir=${HOME}/.local/share/code-server/User
    local settings_json=${settings_dir}/settings.json
    mkdir -p ${settings_dir}

cat > "${settings_json}" <<EOL
{
    "github.copilot.advanced": {},
    "files.exclude": {
        "**/.*": true
    }
}
EOL

}

install_code_server() {
    mkdir -p ${service_parent_install_dir}
    # Install code server
    wget -P ${service_parent_install_dir} ${service_download_url}
    tar -zxf ${service_tgz_path} -C ${service_parent_install_dir}
    # Add copilot
    rsync -avzq -e "ssh ${resource_ssh_usercontainer_options}" ${USER_CONTAINER_HOST}:${service_copilot_usercontainer_path} ${service_parent_install_dir}
    #wget -P ${service_parent_install_dir} -O ${service_copilot_vsix_path} ${service_copilot_url}
    ${service_exec} --install-extensions ${service_copilot_vsix_path}
    # Initialize default settings
    init_code_server_settings
}

. /etc/os-release
# Check if the ID or NAME variable indicates CentOS
if [[ "$ID" == "centos" || "$NAME" == *"CentOS"* ]]; then
    echo; echo
    displayErrorMessage "Code Server is no longer supported on CentOS 7"
    exit 1
fi

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

service_copilot_vsix_path=${service_parent_install_dir}/GitHub.copilot-latest.vsix

if [ ! -f ${service_exec} ]; then
    echo "Executable ${service_exec} not found"
    echo "Installing code server"
    install_code_server
fi

if [ ! -f ${service_exec} ]; then
    displayErrorMessage "Error missing ${service_exec}"
    sleep 1
    exit 1
fi

