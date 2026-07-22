################################################################################
# Interactive Session Service Starter - Open Notebook
#
# Purpose: Start the Open Notebook stack (SurrealDB + open-notebook) with
#          Docker Compose behind a pw endpoint
# Runs on: Controller or compute node
# Called by: Workflow after controller setup
#
# Required Environment Variables:
#   - pw_endpoints_args: Arguments for pw endpoints run (--name, ...)
#   - open_notebook_image / surrealdb_image: Docker images
#   - notebook_data_dir / surreal_data_dir: Data directories
#   - opennotebook_encryption_key: Encryption key for stored secrets
################################################################################

set -x

mkdir -p "${surreal_data_dir}" "${notebook_data_dir}"

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

echo "::group::Image Pulls"
# Pull images on the node where the job runs, before the endpoint registers,
# so the run only completes once the stack can actually start. Images are NOT
# pre-pulled on the controller because controller and compute nodes do not
# share a Docker image cache.
echo "::notice::Pulling ${surrealdb_image}..."
${docker_cmd} pull "${surrealdb_image}"

echo "::notice::Pulling ${open_notebook_image}..."
${docker_cmd} pull "${open_notebook_image}"
echo "::endgroup::"

# Use a unique Docker Compose project name scoped to this run to avoid collisions
export project_name="open_notebook_$(echo "${PW_JOB_ID:-$$}" | tr '.' '_')"
export docker_cmd

# The compose stack is owned by the docker daemon, not the endpoint's process
# tree, so teardown needs cancel.sh (run by the cleanup trap) to bring it down
cat > cancel.sh <<EOF
#!/bin/bash
${docker_cmd} compose -p ${project_name} down --remove-orphans
EOF
chmod +x cancel.sh

echo "::group::Starting Open Notebook"

# pw endpoints run exports PORT and PW_ENDPOINT_URL to the wrapped command; the
# launcher writes the compose file at runtime because they are unknown before
# launch. The foreground `compose logs -f` keeps the endpoint alive for the
# stack's life.
cat > launch-open-notebook-${PW_JOB_ID}.sh <<'LAUNCHEOF'
#!/bin/bash
set -x
cat > docker-compose.yml <<COMPOSEEOF
services:
  surrealdb:
    image: ${surrealdb_image}
    command: start --log info --user root --pass root rocksdb:/mydata/mydatabase.db
    user: root
    volumes:
      - ${surreal_data_dir}:/mydata
    restart: always

  open_notebook:
    image: ${open_notebook_image}
    ports:
      - "${PORT}:8502"
    environment:
      - API_URL=${PW_ENDPOINT_URL%/}
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
COMPOSEEOF

${docker_cmd} compose -p "${project_name}" -f docker-compose.yml up -d
${docker_cmd} compose -p "${project_name}" ps
exec ${docker_cmd} compose -p "${project_name}" logs -f
LAUNCHEOF
chmod +x launch-open-notebook-${PW_JOB_ID}.sh

pw endpoints run ${pw_endpoints_args} -- ./launch-open-notebook-${PW_JOB_ID}.sh

if [ $? -ne 0 ]; then
    echo "::error title=Error::pw endpoints command failed"
    # Fail loud: without this, wait_for_endpoint polls forever for an endpoint
    # that will never register
    pw workflows runs cancel ${PW_RUN_SLUG}
    exit 1
fi
echo "::endgroup::"
