#!/bin/bash

################################################################################
# Interactive Session Service Starter - Open Notebook
#
# Purpose: Start the Open Notebook stack (SurrealDB + open-notebook) using Docker
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - service_port: Allocated port for the web UI (from session_runner)
#   - service_opennotebook_data_dir: Host path for persistent data
#   - service_opennotebook_encryption_key: Encryption key for Open Notebook
#   - service_opennotebook_image_tag: Open Notebook image tag (default: v1-latest)
################################################################################

set -ex

if [ -z "${service_opennotebook_data_dir}" ]; then
    service_opennotebook_data_dir="${HOME}/open-notebook-data"
fi

if [ -z "${service_opennotebook_image_tag}" ]; then
    service_opennotebook_image_tag="v1-latest"
fi

# Fixed encryption key — authentication is disabled for this deployment
service_opennotebook_encryption_key="open-notebook-default-key"

open_notebook_image="lfnovo/open_notebook:${service_opennotebook_image_tag}"
surrealdb_image="surrealdb/surrealdb:v2"

surreal_data_dir="${service_opennotebook_data_dir}/surreal_data"
notebook_data_dir="${service_opennotebook_data_dir}/notebook_data"

mkdir -p "${surreal_data_dir}" "${notebook_data_dir}"

# Initialize cancel script
echo '#!/bin/bash' > "${PW_PARENT_JOB_DIR}/cancel.sh"
chmod +x "${PW_PARENT_JOB_DIR}/cancel.sh"

# Ensure the Docker daemon is running (no-op if already running or not systemctl-managed)
sudo systemctl start docker || true

# Detect docker command: prefer without sudo, fall back to sudo docker
if docker info &>/dev/null; then
    docker_cmd="docker"
    echo "$(date) Docker is accessible without sudo"
elif sudo docker info &>/dev/null; then
    docker_cmd="sudo docker"
    echo "$(date) Docker requires sudo"
else
    echo "$(date) ERROR: Docker is not available on this system" >&2
    exit 1
fi
echo "$(date) Using docker command: ${docker_cmd}"

# Pull images on the node where the job runs.
# Images are NOT pre-pulled on the controller because controller and compute
# nodes do not share a Docker image cache.
echo "$(date) Pulling ${surrealdb_image} ..."
${docker_cmd} pull "${surrealdb_image}"

echo "$(date) Pulling ${open_notebook_image} ..."
${docker_cmd} pull "${open_notebook_image}"

# Use a unique Docker Compose project name scoped to this job to avoid collisions
project_name="open_notebook_${PW_JOB_ID:-$$}"

# Write a docker-compose.yml with the allocated service_port bound to the web UI
cat > "${PW_PARENT_JOB_DIR}/docker-compose.yml" <<EOF
services:
  surrealdb:
    image: ${surrealdb_image}
    restart: unless-stopped
    pull_policy: never
    command:
      - start
      - --log=warn
      - --user=root
      - --pass=root
      - --allow-experimental=graphql
      - rocksdb:/mydata/mydatabase.db
    volumes:
      - ${surreal_data_dir}:/mydata

  open_notebook:
    image: ${open_notebook_image}
    restart: unless-stopped
    pull_policy: never
    ports:
      - "${service_port}:8502"
    environment:
      OPEN_NOTEBOOK_ENCRYPTION_KEY: "${service_opennotebook_encryption_key}"
      SURREAL_URL: "ws://surrealdb:8000/rpc"
      SURREAL_USER: "root"
      SURREAL_PASSWORD: "root"
      SURREAL_NAMESPACE: "open_notebook"
      SURREAL_DATABASE: "open_notebook"
    volumes:
      - ${notebook_data_dir}:/app/data
    depends_on:
      - surrealdb
EOF

# Write the cancel script before starting, so cleanup works even if start fails
echo "${docker_cmd} compose -p ${project_name} down --remove-orphans" >> "${PW_PARENT_JOB_DIR}/cancel.sh"

# Start the stack
${docker_cmd} compose -p "${project_name}" -f "${PW_PARENT_JOB_DIR}/docker-compose.yml" up -d

echo "$(date) Open Notebook stack started on port ${service_port}"

# Keep job alive indefinitely; platform stops it via cancel.sh
sleep inf
