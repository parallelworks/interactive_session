#!/bin/bash
# Starts PostgreSQL/pgvector. Initializes the data directory on first run.
# Sourced by start-template-v3.sh or restart-pgvector.sh.
# Can also be run directly: bash start-pgvector.sh  (auto-loads service.env)

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

echo "::notice::Starting PostgreSQL/pgvector..."

if [ ! -f "$DATA/pgdata/PG_VERSION" ]; then
  echo "::notice::Initializing PostgreSQL data directory..."
  singularity exec \
    --bind "$DATA/pgdata:/var/lib/postgresql/data" \
    "$SIF/pgvector.sif" \
    /usr/lib/postgresql/15/bin/initdb \
      -D /var/lib/postgresql/data \
      -U myuser \
      --auth-host=trust \
      --auth-local=trust
fi

stop_existing pgvector

# PostgreSQL writes postmaster.pid to the data dir. After a hard kill the file
# can linger and cause the next server to start in crash-recovery mode (which
# blocks connections longer). Wait for the old process to fully exit, then
# remove the stale lock so the new instance starts clean.
_pg_pid=$(head -1 "$DATA/pgdata/postmaster.pid" 2>/dev/null || true)
if [ -n "$_pg_pid" ] && kill -0 "$_pg_pid" 2>/dev/null; then
  echo "::notice::Waiting for old PostgreSQL (PID $_pg_pid) to exit..."
  _i=0
  while kill -0 "$_pg_pid" 2>/dev/null && [ $_i -lt 15 ]; do
    sleep 1; _i=$((_i + 1))
  done
  kill -0 "$_pg_pid" 2>/dev/null && kill -9 "$_pg_pid" 2>/dev/null || true
fi
rm -f "$DATA/pgdata/postmaster.pid"

run_bg pgvector \
  singularity exec \
    --writable-tmpfs \
    --bind "$DATA/pgdata:/var/lib/postgresql/data" \
    "$SIF/pgvector.sif" \
    /usr/lib/postgresql/15/bin/postgres \
      -D /var/lib/postgresql/data \
      -c "unix_socket_directories=/tmp" \
      -c "port=$PG_PORT"

wait_for_port "$PG_PORT" "PostgreSQL"

# PostgreSQL accepts the TCP connection before finishing recovery; wait until
# it can actually serve queries before attempting DDL.
echo "::notice::Waiting for PostgreSQL to accept connections..."
pg_ready_attempts=0
until singularity exec \
  --bind "$DATA/pgdata:/var/lib/postgresql/data" \
  "$SIF/pgvector.sif" \
  /usr/lib/postgresql/15/bin/psql \
    -h localhost -p "$PG_PORT" -U myuser -d postgres \
    -c "SELECT 1" >/dev/null 2>&1; do
  sleep 1
  pg_ready_attempts=$((pg_ready_attempts + 1))
  if [ "$pg_ready_attempts" -ge 90 ]; then
    echo "::error::PostgreSQL did not accept connections within 90s"
    exit 1
  fi
done
echo "::notice::PostgreSQL is accepting connections"

singularity exec \
  --bind "$DATA/pgdata:/var/lib/postgresql/data" \
  "$SIF/pgvector.sif" \
  /usr/lib/postgresql/15/bin/psql \
    -h localhost -p "$PG_PORT" -U myuser -d postgres \
    -c "SELECT 1 FROM pg_database WHERE datname='mydatabase'" \
  | grep -q 1 || \
singularity exec \
  --bind "$DATA/pgdata:/var/lib/postgresql/data" \
  "$SIF/pgvector.sif" \
  /usr/lib/postgresql/15/bin/psql \
    -h localhost -p "$PG_PORT" -U myuser -d postgres \
    -c "CREATE DATABASE mydatabase;"
