#!/usr/bin/env bash
set -o pipefail

mkdir -p "${n8n_data_dir}"
chmod 777 "${n8n_data_dir}" -Rf