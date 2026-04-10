set -o pipefail

################################################################################
# Interactive Session Controller - WebShell (ttyd terminal)
#
# Purpose: Install and configure ttyd web terminal for interactive session
# Runs on: Controller node with internet access
# Called by: Workflow preprocessing step
#
# Required Environment Variables:
#   - service_parent_install_dir: Install directory (default: ${HOME}/pw/software)
#   - service_novnc_tgz_basename: noVNC tarball name (includes ttyd binary)
#   - juice_use_juice: Enable Juice for remote GPU access (optional)
################################################################################

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
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
    git checkout legacy

    # 6. Extract tgz
    tar -zxf ${service_novnc_tgz_repo_path} -C ${service_parent_install_dir}

    # 7. Clean
    cd ../
    rm -rf interactive_session

}

# Juice: Remote GPU access service (https://docs.juicelabs.co/docs/juice/intro)
# Allows running compute workloads on remote GPUs when local GPUs are unavailable
download_and_install_juice() {
    # Configuration
    local OUTPUT_FILE="juice.tgz"

    # Step 1: Get download URL from JuiceLabs API
    echo "::notice::Fetching JuiceLabs download URL..."
    download=$(curl -s 'https://electra.juicelabs.co/v2/public/download/linux' | python3 -c "import sys, json; print(json.load(sys.stdin)['url'])")


    if [ -z "$download" ]; then
        echo "::error title=Error::Download URL is empty"
        exit 1
    fi
    echo "::notice::Found download URL: $download"

    # Step 2: Prepare install directory
    mkdir -p "${juice_install_dir}"
    cd "${juice_install_dir}" || exit 1

    # Step 3: Install prerequisites
    sudo dnf install -y wget libatomic numactl-libs || {
        echo "::error title=Error::Failed to install dependencies"
        exit 1
    }

    # Step 4: Download Juice agent
    echo "::notice::Downloading Juice agent..."
    wget -O "$OUTPUT_FILE" "$download" || {
        echo "::error title=Error::Failed to download file"
        exit 1
    }

    # Step 5: Extract archive
    echo "::notice::Extracting Juice agent..."
    tar -xzvf "$OUTPUT_FILE" || {
        echo "::error title=Error::Failed to extract $OUTPUT_FILE"
        exit 1
    }

    echo "::notice::Juice agent successfully installed in ${juice_install_dir}"
}

mkdir -p ${service_parent_install_dir}

service_novnc_tgz_stem=$(echo ${service_novnc_tgz_basename} | sed "s|.tar.gz||g" | sed "s|.tgz||g")
service_novnc_install_dir=${service_parent_install_dir}/${service_novnc_tgz_stem}

echo "::group::noVNC Installation"
if ! [ -d "${service_novnc_install_dir}" ]; then
    echo "::notice::Downloading and installing ${service_novnc_install_dir}"
    download_and_install
fi

if ! [ -d "${service_novnc_install_dir}" ]; then
    echo "::error title=Error::Failed to install ${service_novnc_install_dir}"
    exit 1
fi


# Check if the file exists
if ! [ -f "${service_novnc_install_dir}/ttyd.x86_64" ]; then
    echo "::error title=Error::Missing file ${service_novnc_install_dir}/ttyd.x86_64"
    exit 1
else
    chmod +x "${service_novnc_install_dir}/ttyd.x86_64"
fi
echo "::endgroup::"


# Juice
if [[ "${juice_use_juice}" == "true" ]]; then
    echo "::group::Juice Setup"
    if [ -z "${juice_exec}" ]; then
        juice_install_dir=${service_parent_install_dir}/juice
        juice_exec=${service_parent_install_dir}/juice/juice
        if ! [ -f ${juice_exec} ]; then
            echo "::notice title=Info::Installing Juice"
            mkdir -p ${juice_install_dir}
            download_and_install_juice
        fi
        if ! [ -f ${juice_exec} ]; then
            echo "::error title=Error::Juice installation failed"
            exit 1
        fi
    fi
    echo "::endgroup::"
fi