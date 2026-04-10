#!/bin/bash

################################################################################
# Interactive Session Service Starter - Open Notebook
#
# Purpose: Start the Open Notebook stack (SurrealDB + open-notebook) using Docker
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
################################################################################

set -ex

mkdir -p "${surreal_data_dir}" "${notebook_data_dir}"

# Initialize cancel script
echo '#!/bin/bash' > "${PW_PARENT_JOB_DIR}/cancel.sh"
chmod +x "${PW_PARENT_JOB_DIR}/cancel.sh"

# Ensure the Docker daemon is running (no-op if already running or not systemctl-managed)
sudo systemctl start docker || true

# Detect docker command: prefer without sudo, fall back to sudo docker
if docker info &>/dev/null; then
    docker_cmd="docker"
    echo "::notice::Docker is accessible without sudo"
elif sudo docker info &>/dev/null; then
    docker_cmd="sudo docker"
    echo "::notice::Docker requires sudo"
else
    echo "::error title=Error::Docker is not available on this system"
    exit 1
fi
echo "::notice::Using docker command: ${docker_cmd}"

echo "::group::Stack Startup"
# Pull images on the node where the job runs.
# Images are NOT pre-pulled on the controller because controller and compute
# nodes do not share a Docker image cache.
echo "::notice::Pulling ${surrealdb_image}..."
${docker_cmd} pull "${surrealdb_image}"

echo "::notice::Pulling ${open_notebook_image}..."
${docker_cmd} pull "${open_notebook_image}"

# Use a unique Docker Compose project name scoped to this job to avoid collisions
project_name="open_notebook_$(echo "${PW_JOB_ID:-$$}" | tr '.' '_')"

# Sanitize PW_USER: lowercase, no dots (e.g. Matthew.Shaxted -> matthewshaxted)
PW_USER_CLEAN=$(echo "${PW_USER}" | tr '[:upper:]' '[:lower:]' | tr -d '.')

cat > "${PW_PARENT_JOB_DIR}/docker-compose.yml" <<EOF
services:
  surrealdb:
    image: ${surrealdb_image}
    command: start --log info --user root --pass root rocksdb:/mydata/mydatabase.db
    user: root
    ports:
      - "$(pw agent open-port):8000"
    volumes:
      - ${surreal_data_dir}:/mydata
    restart: always

  open_notebook:
    image: ${open_notebook_image}
    ports:
      - "${service_port}:8502"
      - "$(pw agent open-port):5055"
    environment:
      - API_URL=https://${PW_USER_CLEAN}-${SESSION_NAME}
      - OPEN_NOTEBOOK_ENCRYPTION_KEY=${opennotebook_encryption_key}
      - SURREAL_URL=ws://surrealdb:8000/rpc
      - SURREAL_USER=root
      - SURREAL_PASSWORD=root
      - SURREAL_NAMESPACE=open_notebook
      - SURREAL_DATABASE=open_notebook
    volumes:
      - ${notebook_data_dir}:/app/data
    depends_on:
      - surrealdb
    restart: always
EOF


# Write the cancel script before starting, so cleanup works even if start fails
echo "${docker_cmd} compose -p ${project_name} down --remove-orphans" >> "${PW_PARENT_JOB_DIR}/cancel.sh"

# Start the stack
${docker_cmd} compose -p "${project_name}" -f "${PW_PARENT_JOB_DIR}/docker-compose.yml" up -d

echo "::notice::Open Notebook stack started on port ${service_port}"
echo "::endgroup::"

# Keep job alive indefinitely; platform stops it via cancel.sh
sleep inf
