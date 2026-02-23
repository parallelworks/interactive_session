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

if [ -z "${service_opennotebook_data_dir}" ]; then
    service_opennotebook_data_dir="${HOME}/open-notebook-data"
fi

if [ -z "${service_opennotebook_image_tag}" ]; then
    service_opennotebook_image_tag="v1-latest"
fi

if [ -z "${service_opennotebook_encryption_key}" ]; then
    echo "$(date) WARNING: No encryption key set; using default (not recommended for production)."
    service_opennotebook_encryption_key="change-me-to-a-secret-key"
fi

open_notebook_image="lfnovo/open_notebook:${service_opennotebook_image_tag}"
surrealdb_image="surrealdb/surrealdb:v2"

surreal_data_dir="${service_opennotebook_data_dir}/surreal_data"
notebook_data_dir="${service_opennotebook_data_dir}/notebook_data"

mkdir -p "${surreal_data_dir}" "${notebook_data_dir}"

# Use a unique Docker Compose project name scoped to this job to avoid collisions
project_name="open_notebook_${PW_JOB_ID:-$$}"

set -x

# Write the cancel script so the platform can cleanly stop the service
cat > "${PW_PARENT_JOB_DIR}/cancel.sh" <<EOF
#!/bin/bash
docker compose -p ${project_name} down --remove-orphans
EOF
chmod +x "${PW_PARENT_JOB_DIR}/cancel.sh"

# Write a docker-compose.yml for this job, binding service_port to the web UI
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

# Start the stack in the background
docker compose -p "${project_name}" -f "${PW_PARENT_JOB_DIR}/docker-compose.yml" up -d

# Keep job alive indefinitely; platform stops it via cancel.sh
sleep inf
