#!/usr/bin/env bash
set -o pipefail

################################################################################
# Interactive Session Controller - n8n
#
# Purpose: Minimal setup for n8n service on login node
# Runs on: Controller node with internet access
# Called by: Workflow preprocessing step
#
# NOTE: Do NOT pull Docker images here. Login and compute nodes do not share
# image storage, so images must be pulled on the compute node at runtime.
#
# Required Environment Variables:
#   - service_parent_install_dir: Install directory (default: ${HOME}/pw/software)
################################################################################

if ! [ -z ${PW_PARENT_JOB_DIR} ]; then
    cd ${PW_PARENT_JOB_DIR}
fi

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

mkdir -p "${service_parent_install_dir}"
