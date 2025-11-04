
displayErrorMessage() {
    echo $(date): $1
}


init_code_server_settings() {
    local settings_dir=${HOME}/.local/share/code-server/User
    local settings_json=${settings_dir}/settings.json
    mkdir -p ${settings_dir}

cat > "${settings_json}" <<EOL
{
    "github.copilot.advanced": {},
    "cline.apiProvider": "openai-compatible",
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

    # install latest cline
    if ! ${service_exec} --list-extensions | grep -q '^saoudrizwan.claude-dev$'; then
        curl -s https://api.github.com/repos/cline/cline/releases/latest \
            | jq -r '.assets[] | select(.name | endswith(".vsix")) | .browser_download_url' \
            | xargs -n 1 wget -O cline-latest.vsix
        ${service_exec} --install-extension cline-latest.vsix --extensions-dir ${HOME}/.local/share/code-server/extensions
    fi

    # Initialize default settings
    init_code_server_settings
    
    # Clean tgz
    rm ${service_tgz_path}
}

download_and_install_juice() {
    # Configuration
    local OUTPUT_FILE="juice.tgz"

    # Step 1: Get download URL from JuiceLabs API
    echo "Fetching JuiceLabs download URL..."
    download=$(curl -s 'https://electra.juicelabs.co/v2/public/download/linux' | python3 -c "import sys, json; print(json.load(sys.stdin)['url'])")


    if [ -z "$download" ]; then
        echo "ERROR: Download URL is empty"
        exit 1
    fi
    echo "Found download URL: $download"

    # Step 2: Prepare install directory
    mkdir -p "${juice_install_dir}"
    cd "${juice_install_dir}" || exit 1

    # Step 3: Install prerequisites
    sudo dnf install -y wget libatomic numactl-libs || {
        echo "ERROR: Failed to install dependencies"
        exit 1
    }

    # Step 4: Download Juice agent
    echo "Downloading Juice agent..."
    wget -O "$OUTPUT_FILE" "$download" || {
        echo "ERROR: Failed to download file"
        exit 1
    }

    # Step 5: Extract archive
    echo "Extracting Juice agent..."
    tar -xzvf "$OUTPUT_FILE" || {
        echo "ERROR: Failed to extract $OUTPUT_FILE"
        exit 1
    }

    echo "Juice agent successfully installed in ${juice_install_dir}"
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
mkdir -p ${service_parent_install_dir}

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


curl -L -o github.copilot-1.388.0.vsix \
"https://github.gallery.vsassets.io/_apis/public/gallery/publisher/github/extension/copilot/1.388.0/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage"


# Copilot extension
copilot_extension_path=${service_parent_install_dir}/github.copilot-1.388.0.vsix
if [ ! -f ${copilot_extension_path} ]; then
    echo "Extension ${copilot_extension_path} not found"
    echo "Downloading and installing extension ${copilot_extension_path}"
    curl -L -o ${copilot_extension_path} "https://github.gallery.vsassets.io/_apis/public/gallery/publisher/github/extension/copilot/1.388.0/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage"
    ${service_exec} --install-extension ${copilot_extension_path} --extensions-dir ${HOME}/.local/share/code-server/extensions
fi

# Copilot chat extension
copilot_chat_extension_path=${service_parent_install_dir}/github.copilot-chat-0.10.1.vsix
if [ ! -f ${copilot_chat_extension_path} ]; then
    echo "Extension ${copilot_chat_extension_path} not found"
    echo "Downloading and installing extension ${copilot_chat_extension_path}"
    curl -L -o ${copilot_chat_extension_path} "https://github.gallery.vsassets.io/_apis/public/gallery/publisher/github/extension/copilot-chat/0.10.1/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage"
    ${service_exec} --install-extension ${copilot_chat_extension_path} --extensions-dir ${HOME}/.local/share/code-server/extensions
fi


if [ ! -f ${service_exec} ]; then
    displayErrorMessage "Error missing ${service_exec}"
    sleep 1
    exit 1
fi

# Juice
if [[ "${juice_use_juice}" == "true" ]]; then
    if [ -z "${juice_exec}" ]; then
        juice_install_dir=${service_parent_install_dir}/juice
        juice_exec=${service_parent_install_dir}/juice/juice
        if ! [ -f ${juice_exec} ]; then
            echo "INFO: Installing Juice"
            mkdir -p ${juice_install_dir}
            download_and_install_juice
        fi
        if ! [ -f ${juice_exec} ]; then
            echo "ERROR: Juice installation failed"
            exit 1
        fi
    fi
fi
