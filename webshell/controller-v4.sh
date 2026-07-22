set -o pipefail

################################################################################
# Interactive Session Controller - WebShell (ttyd terminal)
#
# Purpose: Install ttyd web terminal for the endpoint session
# Runs on: Controller node with internet access
# Called by: Workflow preprocessing step
#
# Required Environment Variables:
#   - service_parent_install_dir: Install directory (default: ${HOME}/pw/software)
#   - service_novnc_tgz_basename: noVNC tarball name (includes ttyd binary)
################################################################################

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

download_and_install() {
    # 1. Clone the repository with --no-checkout
    export GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null '
    # Needed for emed
    git config --global --unset http.sslbackend
    git clone --no-checkout https://github.com/parallelworks/interactive_session.git

    # 2. Navigate into the repository directory
    cd interactive_session

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
