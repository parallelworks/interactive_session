#!/usr/bin/env bash
set -o pipefail

################################################################################
# Interactive Session Controller - Open Notebook
#
# Purpose: Verify Docker is available and pre-pull the required images
# Runs on: Controller node with internet access
# Called by: Workflow preprocessing step
#
# Required Environment Variables:
#   - service_opennotebook_image_tag: Open Notebook image tag (default: v1-latest)
################################################################################

if [ -z "${service_opennotebook_image_tag}" ]; then
    service_opennotebook_image_tag="v1-latest"
fi

open_notebook_image="lfnovo/open_notebook:${service_opennotebook_image_tag}"
surrealdb_image="surrealdb/surrealdb:v2"

# Verify Docker is installed and the daemon is reachable
if ! command -v docker &>/dev/null; then
    echo "$(date) ERROR: Docker is not installed on this host."
    echo "$(date) ERROR: Please select a resource that has Docker available."
    exit 1
fi

if ! docker info &>/dev/null; then
    echo "$(date) ERROR: Docker daemon is not running or is not accessible."
    exit 1
fi

echo "$(date) INFO: Docker is available."

# Pull SurrealDB image if not already present
if ! docker image inspect "${surrealdb_image}" &>/dev/null; then
    echo "$(date) INFO: Pulling ${surrealdb_image} ..."
    docker pull "${surrealdb_image}" || {
        echo "$(date) ERROR: Failed to pull ${surrealdb_image}" >&2
        exit 1
    }
else
    echo "$(date) INFO: ${surrealdb_image} already present, skipping pull."
fi

# Pull Open Notebook image if not already present
if ! docker image inspect "${open_notebook_image}" &>/dev/null; then
    echo "$(date) INFO: Pulling ${open_notebook_image} ..."
    docker pull "${open_notebook_image}" || {
        echo "$(date) ERROR: Failed to pull ${open_notebook_image}" >&2
        exit 1
    }
else
    echo "$(date) INFO: ${open_notebook_image} already present, skipping pull."
fi

echo "$(date) INFO: Controller setup complete."
