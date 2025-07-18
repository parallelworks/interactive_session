#service_download_url="https://github.com/coder/code-server/releases/download/v4.92.2/code-server-4.92.2-linux-amd64.tar.gz"

# The URL downloads a different file when using wget/curl than when pasting it in the browser
# service_copilot_url="https://marketplace.visualstudio.com/_apis/public/gallery/publishers/GitHub/vsextensions/copilot/latest/vspackage"
service_copilot_usercontainer_path="${pw_job_dir}/${service_name}/GitHub.copilot-latest.vsix"

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
    #wget -P ${service_parent_install_dir} -O ${service_copilot_vsix_path} ${service_copilot_url}
    ${service_exec} --install-extension ${service_copilot_vsix_path} --extensions-dir ${HOME}/.local/share/code-server/extensions
    # Initialize default settings
    init_code_server_settings
    # Clean tgz
    rm ${service_tgz_path}
}

download_and_install_juice() {
    # Configuration
    local REPO="parallelworks/interactive_session"
    local BRANCH="juice-v2"
    local FILE_PATH="downloads/juice/juice-gpu-linux.tar.gz"
    local OUTPUT_FILE="juice-gpu-linux.tar.gz"
    local RAW_URL="https://raw.githubusercontent.com/$REPO/$BRANCH/$FILE_PATH"
    local LFS_API_URL="https://github.com/$REPO.git/info/lfs/objects/batch"

    # Check for jq dependency
    if ! command -v jq >/dev/null 2>&1; then
        echo "ERROR: jq is required to parse JSON."
        exit 1
    fi

    # Step 1: Download the LFS pointer file
    echo "Fetching LFS pointer file..."
    curl -L -s -o lfs-pointer.txt "$RAW_URL" || {
        echo "ERROR: Failed to download LFS pointer from $RAW_URL"
        exit 1
    }

    # Step 2: Extract oid and size from the pointer file
    if [ ! -s lfs-pointer.txt ]; then
        echo "ERROR: LFS pointer file is empty or not found"
        exit 1
    fi

    OID=$(grep '^oid' lfs-pointer.txt | awk '{print $2}' | cut -d':' -f2)
    SIZE=$(grep '^size' lfs-pointer.txt | awk '{print $2}')

    if [ -z "$OID" ] || [ -z "$SIZE" ]; then
        echo "ERROR: Could not extract oid or size from LFS pointer"
        cat lfs-pointer.txt
        exit 1
    fi

    echo "Found LFS pointer: oid=$OID, size=$SIZE bytes"

    # Step 3: Query LFS API to get the download URL
    echo "Querying LFS API for download URL..."
    curl -L -s -o lfs-response.json "$LFS_API_URL" \
        -H "Accept: application/vnd.git-lfs+json" \
        -H "Content-Type: application/vnd.git-lfs+json" \
        -d "{\"operation\": \"download\", \"transfers\": [\"basic\"], \"objects\": [{\"oid\": \"$OID\", \"size\": $SIZE}]}" || {
        echo "ERROR: Failed to query LFS API"
        exit 1
    }

    # Step 4: Extract the download URL from the JSON response
    DOWNLOAD_URL=$(jq -r '.objects[0].actions.download.href' lfs-response.json 2>/dev/null)
    if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ]; then
        echo "ERROR: Could not extract download URL from LFS API response"
        cat lfs-response.json
        exit 1
    fi

    echo "Found download URL: $DOWNLOAD_URL"

    # Step 5: Download the full file
    echo "Downloading file..."
    curl -L -o "$OUTPUT_FILE" "$DOWNLOAD_URL" || {
        echo "ERROR: Failed to download file from $DOWNLOAD_URL"
        exit 1
    }

    # Step 6: Move file
    mv ${OUTPUT_FILE} ${juice_install_dir}
    
    # Step 7: Extraxct tgz
    cd ${juice_install_dir}
    tar -zxvf ${OUTPUT_FILE}
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

if [ ! -f ${service_exec} ]; then
    displayErrorMessage "Error missing ${service_exec}"
    sleep 1
    exit 1
fi

