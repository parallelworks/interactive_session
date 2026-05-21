#!/bin/bash
# Starts MeiliSearch.
# Sourced by start-template-v3.sh or restart-meilisearch.sh.
# Can also be run directly: bash start-meilisearch.sh  (auto-loads service.env)

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

echo "::notice::Starting MeiliSearch..."
MEILI_KEY="$(grep ^MEILI_MASTER_KEY "$BASE/.env" | cut -d= -f2-)"
stop_existing meilisearch
run_bg meilisearch \
  singularity exec \
    --writable-tmpfs \
    --bind "$DATA/meili:/meili_data" \
    --env MEILI_NO_ANALYTICS=true \
    --env "MEILI_MASTER_KEY=$MEILI_KEY" \
    "$SIF/meilisearch.sif" \
    /bin/meilisearch --db-path /meili_data/data.ms --http-addr "0.0.0.0:$MEILI_PORT"

wait_for_port "$MEILI_PORT" "MeiliSearch"
