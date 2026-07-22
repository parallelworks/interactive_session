#!/usr/bin/env bash
set -o pipefail

################################################################################
# Interactive Session Service Starter - n8n via Docker behind a pw endpoint
#
# Purpose: Start n8n service via Docker on the endpoint-assigned port
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

if [ -z ${n8n_image_tag} ]; then
    n8n_image_tag=1.123.4
fi

# Unique container name per run — prevents conflicts when multiple
# sessions run on the same host
container_name="n8n_${PW_RUN_SLUG}"

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

# The container is owned by the docker daemon, not the endpoint's process
# tree, so teardown needs cancel.sh (run by the cleanup trap) to stop it
cat > cancel.sh <<EOF
#!/bin/bash
${docker_cmd} stop ${container_name} 2>/dev/null || true
${docker_cmd} rm ${container_name} 2>/dev/null || true
EOF
chmod +x cancel.sh

echo "::group::Starting n8n"

# pw endpoints run exports PORT and PW_ENDPOINT_URL to the wrapped command;
# the launcher reads them at runtime (they are unknown before launch). The
# foreground `docker logs -f` keeps the endpoint alive for the container's life.
cat > launch-n8n-${PW_JOB_ID}.sh <<EOF
#!/bin/bash
${docker_cmd} pull docker.io/n8nio/n8n:${n8n_image_tag}
${docker_cmd} stop ${container_name} 2>/dev/null || true  # clean up any stale containers
${docker_cmd} rm ${container_name} 2>/dev/null || true
${docker_cmd} run -d \\
    --name "${container_name}" \\
    --restart unless-stopped \\
    -p "\${PORT}:\${PORT}" \\
    -e N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=false \\
    -e GENERIC_TIMEZONE=UTC \\
    -e N8N_HOST=localhost \\
    -e N8N_PORT="\${PORT}" \\
    -e N8N_PROTOCOL=http \\
    -e N8N_DIAGNOSTICS_ENABLED=false \\
    -e N8N_VERSION_NOTIFICATIONS_ENABLED=false \\
    -e N8N_EDITOR_BASE_URL="\${PW_ENDPOINT_URL}" \\
    -e WEBHOOK_URL="\${PW_ENDPOINT_URL}" \\
    -v "${n8n_data_dir}:/home/node/.n8n" \\
    docker.io/n8nio/n8n:${n8n_image_tag}
${docker_cmd} ps --filter "name=${container_name}"
exec ${docker_cmd} logs -f "${container_name}"
EOF
chmod +x launch-n8n-${PW_JOB_ID}.sh

pw endpoints run ${pw_endpoints_args} -- ./launch-n8n-${PW_JOB_ID}.sh

if [ $? -ne 0 ]; then
    echo "::error title=Error::pw endpoints command failed"
    # Fail loud: without this, wait_for_endpoint polls forever for an endpoint
    # that will never register
    pw workflows runs cancel ${PW_RUN_SLUG}
    exit 1
fi
echo "::endgroup::"
