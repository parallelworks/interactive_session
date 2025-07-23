if [ -z ${service_novnc_parent_install_dir} ]; then
    service_novnc_parent_install_dir=${HOME}/pw/software
fi

#service_novnc_tgz_basename=noVNC-1.3.0.tgz

download_and_install() {
    # 1. Clone the repository with --no-checkout
    export GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null '
    # Needed for emed
    git config --global --unset http.sslbackend
    git clone --no-checkout https://github.com/parallelworks/interactive_session.git

    # 2. Navigate into the repository directory
    cd interactive_session
    #git checkout download-dependencies

    # 3. Initialize sparse-checkout
    git sparse-checkout init

    # 4. Configure sparse-checkout to include only the desired directory
    service_novnc_tgz_repo_path="downloads/vnc/${service_novnc_tgz_basename}"
    echo "${service_novnc_tgz_repo_path}" > .git/info/sparse-checkout

    # 5. Perform the checkout
    git checkout

    # 6. Extract tgz
    tar -zxf ${service_novnc_tgz_repo_path} -C ${service_novnc_parent_install_dir}

    # 7. Clean
    cd ../
    rm -rf interactive_session
    
}

download_and_install_juice() {
    # Configuration
    local REPO="parallelworks/interactive_session"
    local BRANCH="main"
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


displayErrorMessage() {
    echo $(date): $1
}

echo; echo

mkdir -p ${service_novnc_parent_install_dir}

service_novnc_tgz_stem=$(echo ${service_novnc_tgz_basename} | sed "s|.tar.gz||g" | sed "s|.tgz||g")
service_novnc_install_dir=${service_novnc_parent_install_dir}/${service_novnc_tgz_stem}

if ! [ -d "${service_novnc_install_dir}" ]; then
    echo "Downloading and installing ${service_novnc_install_dir}"
    download_and_install
fi

if ! [ -d "${service_novnc_install_dir}" ]; then
    echo
    displayErrorMessage "Failed to install ${service_novnc_install_dir}"
    exit 1
fi


# Check if the file exists
if ! [ -f "${service_novnc_install_dir}/ttyd.x86_64" ]; then
    echo
    displayErrorMessage "Missing file ${service_novnc_install_dir}/ttyd.x86_64"
    exit 1
else
    chmod +x "${service_novnc_install_dir}/ttyd.x86_64" 
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