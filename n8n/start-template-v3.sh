#!/usr/bin/env bash
set -o pipefail

################################################################################
# Interactive Session Service Starter - n8n
#
# Purpose: Start n8n service via Docker Compose on allocated port
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
################################################################################

start_rootless_docker() {
    local MAX_RETRIES=20
    local RETRY_INTERVAL=2
    local ATTEMPT=1

    export XDG_RUNTIME_DIR=/run/user/$(id -u)
    dockerd-rootless-setuptool.sh install
    PATH=/usr/bin:/sbin:/usr/sbin:$PATH dockerd-rootless.sh --exec-opt native.cgroupdriver=cgroupfs > docker-rootless.log 2>&1 &

    # Wait for Docker daemon to be ready
    echo "::group::Waiting for Docker daemon to start"
    until docker info > /dev/null 2>&1; do
        if [ $ATTEMPT -le $MAX_RETRIES ]; then
            echo "Attempt $ATTEMPT of $MAX_RETRIES: waiting for Docker daemon..."
            sleep $RETRY_INTERVAL
            ((ATTEMPT++))
        else
            echo "::endgroup::"
            echo "::error title=Error::Docker daemon failed to start after $MAX_RETRIES attempts."
            return 1
        fi
    done
    echo "::endgroup::"
    echo "::notice::Docker daemon is ready!"
    return 0
}

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

if [ -z ${n8n_image_tag} ]; then
    n8n_image_tag=1.123.4
fi

# Initialize cancel script
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh

echo "::group::Docker Setup"

# Determine which Docker mode to use
if which docker >/dev/null 2>&1 && [[ "${service_rootless_docker}" == "true" ]]; then
    if ! dockerd-rootless-setuptool.sh check; then
        echo "::error title=Error::Rootless Docker is not supported on this system"
        exit 1
    fi
    echo "::notice::Starting rootless Docker daemon"
    start_rootless_docker
    docker_cmd="docker"
elif sudo -n true 2>/dev/null && which docker >/dev/null 2>&1; then
    echo "::notice::Using privileged Docker (sudo)"
    sudo systemctl start docker
    docker_cmd="sudo docker"
else
    echo "::notice::No sudo access — falling back to rootless Docker"
    if ! dockerd-rootless-setuptool.sh check; then
        echo "::error title=Error::Rootless Docker is not supported on this system"
        exit 1
    fi
    start_rootless_docker
    docker_cmd="docker"
fi

echo "Docker command: ${docker_cmd}"
echo "::endgroup::"


# Generate docker-compose.yml from template by substituting placeholders
sed \
    -e "s|__BASE_PATH__|${basepath}|g" \
    -e "s|__PORT__|${service_port}|g" \
    -e "s|__N8N_IMAGE_TAG__|${n8n_image_tag}|g" \
    -e "s|__N8N_DATA_DIR__|${n8n_data_dir}|g" \
    ${PW_PARENT_JOB_DIR}/n8n/docker-compose.yml.template > docker-compose.yml

echo "::group::docker-compose.yml"
cat docker-compose.yml
echo "::endgroup::"

# Write cancel script before starting containers
cat >> cancel.sh <<EOF
${docker_cmd} compose down --volumes
EOF

echo "::group::Starting n8n"
$docker_cmd compose pull
$docker_cmd compose down 2>/dev/null || true  # clean up any stale containers
$docker_cmd compose up -d
$docker_cmd compose ps
echo "::endgroup::"

echo "::notice::n8n is up → http://localhost:${service_port}${basepath}"

echo "::group::n8n logs"
$docker_cmd compose logs -f &
logs_pid=$!
echo "kill ${logs_pid} #docker-logs" >> cancel.sh
echo "::endgroup::"

sleep inf
