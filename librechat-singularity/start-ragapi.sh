#!/bin/bash
# Starts the RAG API.
# Sourced by start-template-v3.sh or restart-ragapi.sh.
# Can also be run directly: bash start-ragapi.sh  (auto-loads service.env)

_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -f stop_existing > /dev/null 2>&1; then
  source "$_UTILS_DIR/utils.sh"
fi

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -e
  _svc_env="${SERVICE_ENV:-${HOME}/pw/LibreChat/singularity-data/service.env}"
  [ -f "$_svc_env" ] || { echo "ERROR: service.env not found at $_svc_env. Set SERVICE_ENV=/path/to/service.env" >&2; exit 1; }
  source "$_svc_env"
  if ! which singularity &>/dev/null; then
    module load apptainer 2>/dev/null || module load singularity 2>/dev/null || \
      { echo "ERROR: singularity/apptainer not found." >&2; exit 1; }
  fi
  unset PYTHONPATH PYTHONHOME PERL5LIB PERLLIB PERL5OPT PYTHONSTARTUP LD_LIBRARY_PATH
fi

echo "::notice::Starting RAG API..."
stop_existing ragapi
run_bg ragapi \
  singularity exec \
    --cleanenv \
    --writable-tmpfs \
    --pwd /app \
    --env-file "$CLEAN_ENV" \
    --env DB_HOST=localhost \
    --env "DB_PORT=$PG_PORT" \
    --env POSTGRES_DB=mydatabase \
    --env POSTGRES_USER=myuser \
    --env POSTGRES_PASSWORD=mypassword \
    --env "RAG_PORT=$RAG_PORT" \
    "$SIF/rag_api.sif" \
    python main.py

wait_for_port "$RAG_PORT" "RAG API"
