
check_sudo_access() {
    if ! sudo -n true 2>/dev/null; then
        echo "$(date) ERROR: Cannot $1 without root access"
        exit 1
    fi
}

# if running on rocky9 update the download url
source /etc/os-release
if [[ "$VERSION_ID" == *"9"* ]]; then
    check_sudo_access "nodejs"
    sudo dnf install nodejs -y
    mkdir cesium-app
    cd cesium-app
    npm init -y
    npm install cesium http-server
    npx http-server -p ${service_port}
elif [[ "$VERSION_ID" == *"8"* ]]; then
    echo "$(date) ERROR: This workflow is only supported on Rocky Linux 9"
    exit 1
else
    echo "$(date) ERROR: This workflow is only supported on Rocky Linux 9"
    exit 1
fi

