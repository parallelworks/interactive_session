#!/bin/bash
set -e

if [ -n "${service_parent_install_dir}" ]; then
    container_dir=${service_parent_install_dir}/containers/librechat
    if ! [ -d "${container_dir}" ] && ! [ -w "${service_parent_install_dir}" ]; then
        echo "::warning::container_dir ${container_dir} does not exist and no write permission to ${service_parent_install_dir}. Resetting to ${HOME}/pw/software."
        service_parent_install_dir=${HOME}/pw/software
    fi
else
    service_parent_install_dir=${HOME}/pw/software
fi

# Load singularity/apptainer if not already in PATH
if ! which singularity &> /dev/null; then
    if module load apptainer 2>/dev/null; then
        echo "::notice::Loaded apptainer module"
    elif module load singularity 2>/dev/null; then
        echo "::notice::Loaded singularity module"
    else
        echo "::error title=Error::singularity/apptainer not found in PATH and could not be loaded via module"
        exit 1
    fi
else
    echo "::notice::singularity already available in PATH"
fi

# Unset host env vars that can corrupt the container's Node.js/npm runtime.
# On Cray EX and similar HPC systems, LD_LIBRARY_PATH carries PE paths that
# cause Node to load incompatible native libraries.
unset PYTHONPATH PYTHONHOME PERL5LIB PERLLIB PERL5OPT PYTHONSTARTUP LD_LIBRARY_PATH

SIF=${service_parent_install_dir}/containers

BASE="${PWD}/LibreChat"
DATA="$BASE/singularity-data"
PID_DIR="$DATA/pids"
LOG_DIR="$DATA/logs"

mkdir -p "$DATA/mongodb" "$DATA/meili" "$DATA/pgdata" \
         "$BASE/images" "$BASE/uploads" "$BASE/logs" \
         "$PID_DIR" "$LOG_DIR"

# Bind file used to hide kernel FIPS flag from containers whose OpenSSL 3.x
# auto-activates FIPS mode when /proc/sys/crypto/fips_enabled reads 1.
echo 0 > "$DATA/nofips"

# ── Sanitized env file (Apptainer --env-file can't handle bash math exprs) ───

CLEAN_ENV="$DATA/apptainer.env"
grep -Ev '^\s*(#|$)' "$BASE/.env" \
  | grep -E '^[A-Za-z_][A-Za-z0-9_]+=' \
  | grep -Ev '[*()&|`]' \
  > "$CLEAN_ENV" || true
# Precomputed values for JS math expressions that would break --env-file
echo 'BAN_DURATION=7200000'          >> "$CLEAN_ENV"   # 1000 * 60 * 60 * 2
echo 'SESSION_EXPIRY=900000'         >> "$CLEAN_ENV"   # 1000 * 60 * 15
echo 'REFRESH_TOKEN_EXPIRY=604800000' >> "$CLEAN_ENV"  # (1000*60*60*24) * 7

# ── Port allocation ──────────────────────────────────────────────────────────

echo "::group::Allocating ports"
MONGODB_PORT=$(pw agent open-port) || { echo "::error title=Error::Failed to allocate MongoDB port"; exit 1; }
[ -n "$MONGODB_PORT" ] || { echo "::error title=Error::No MongoDB port returned"; exit 1; }
echo "::notice::MongoDB port: $MONGODB_PORT"
MEILI_PORT=$(pw agent open-port) || { echo "::error title=Error::Failed to allocate MeiliSearch port"; exit 1; }
[ -n "$MEILI_PORT" ] || { echo "::error title=Error::No MeiliSearch port returned"; exit 1; }
echo "::notice::MeiliSearch port: $MEILI_PORT"
PG_PORT=$(pw agent open-port) || { echo "::error title=Error::Failed to allocate PostgreSQL port"; exit 1; }
[ -n "$PG_PORT" ] || { echo "::error title=Error::No PostgreSQL port returned"; exit 1; }
echo "::notice::PostgreSQL port: $PG_PORT"
RAG_PORT=$(pw agent open-port) || { echo "::error title=Error::Failed to allocate RAG API port"; exit 1; }
[ -n "$RAG_PORT" ] || { echo "::error title=Error::No RAG API port returned"; exit 1; }
echo "::notice::RAG API port: $RAG_PORT"
echo "::notice::LibreChat port: $service_port"
echo "::endgroup::"

# ── Helpers ──────────────────────────────────────────────────────────────────

wait_for_port() {
  local port="$1" label="$2"
  echo "::notice::Waiting for $label on port $port..."
  local attempts=0
  until bash -c ">/dev/tcp/localhost/$port" 2>/dev/null; do
    sleep 1
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 60 ]; then
      echo "::error::$label did not start within 60s. Check $LOG_DIR/${label,,}.log"
      exit 1
    fi
  done
  echo "::notice::$label is ready"
}

run_bg() {
  local name="$1"; shift
  nohup "$@" > "$LOG_DIR/$name.log" 2>&1 &
  echo $! > "$PID_DIR/$name.pid"
  echo "::notice::Started $name (PID $!)"
}

stop_existing() {
  local name="$1"
  local pidfile="$PID_DIR/$name.pid"
  if [ -f "$pidfile" ]; then
    local pid
    pid=$(cat "$pidfile")
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" && echo "::notice::Stopped existing $name (PID $pid)"
      sleep 1
    fi
    rm -f "$pidfile"
  fi
}

# ── Cancel script ────────────────────────────────────────────────────────────

cat > "${PW_PARENT_JOB_DIR}/cancel.sh" <<EOF
#!/bin/bash
echo "::group::Stopping LibreChat services"
for svc in librechat ragapi pgvector meilisearch mongodb; do
  pidfile="${PID_DIR}/\${svc}.pid"
  if [ -f "\$pidfile" ]; then
    pid=\$(cat "\$pidfile")
    if kill -0 "\$pid" 2>/dev/null; then
      kill "\$pid" && echo "::notice::Stopped \${svc} (PID \$pid)"
      sleep 1
    fi
    rm -f "\$pidfile"
  fi
done
echo "::endgroup::"
EOF
chmod +x "${PW_PARENT_JOB_DIR}/cancel.sh"

# ── Stop any leftover processes ───────────────────────────────────────────────

echo "::group::Stopping existing processes"
for svc in librechat ragapi pgvector meilisearch mongodb; do
  stop_existing "$svc"
done
echo "::endgroup::"

# ── Services ──────────────────────────────────────────────────────────────────

echo "::group::Starting services"

# ── MongoDB ───────────────────────────────────────────────────────────────────

echo "::notice::Starting MongoDB..."
run_bg mongodb \
  singularity exec \
    --writable-tmpfs \
    --bind "$DATA/mongodb:/data/db" \
    --bind "$DATA/nofips:/proc/sys/crypto/fips_enabled:ro" \
    "$SIF/mongodb.sif" \
    mongod --noauth --dbpath /data/db --bind_ip_all --port $MONGODB_PORT

wait_for_port $MONGODB_PORT "MongoDB"

# ── MeiliSearch ───────────────────────────────────────────────────────────────

echo "::notice::Starting MeiliSearch..."
MEILI_KEY="$(grep ^MEILI_MASTER_KEY "$BASE/.env" | cut -d= -f2-)"
run_bg meilisearch \
  singularity exec \
    --writable-tmpfs \
    --bind "$DATA/meili:/meili_data" \
    --env MEILI_NO_ANALYTICS=true \
    --env "MEILI_MASTER_KEY=$MEILI_KEY" \
    "$SIF/meilisearch.sif" \
    /bin/meilisearch --db-path /meili_data/data.ms --http-addr 0.0.0.0:$MEILI_PORT

wait_for_port $MEILI_PORT "MeiliSearch"

# ── PostgreSQL + pgvector ─────────────────────────────────────────────────────

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

run_bg pgvector \
  singularity exec \
    --writable-tmpfs \
    --bind "$DATA/pgdata:/var/lib/postgresql/data" \
    "$SIF/pgvector.sif" \
    /usr/lib/postgresql/15/bin/postgres \
      -D /var/lib/postgresql/data \
      -c "unix_socket_directories=/tmp" \
      -c "port=$PG_PORT"

wait_for_port $PG_PORT "PostgreSQL"

# Create database if it does not exist yet
singularity exec \
  --bind "$DATA/pgdata:/var/lib/postgresql/data" \
  "$SIF/pgvector.sif" \
  /usr/lib/postgresql/15/bin/psql \
    -h localhost -p $PG_PORT -U myuser -d postgres \
    -c "SELECT 1 FROM pg_database WHERE datname='mydatabase'" \
  | grep -q 1 || \
singularity exec \
  --bind "$DATA/pgdata:/var/lib/postgresql/data" \
  "$SIF/pgvector.sif" \
  /usr/lib/postgresql/15/bin/psql \
    -h localhost -p $PG_PORT -U myuser -d postgres \
    -c "CREATE DATABASE mydatabase;"

# ── RAG API ───────────────────────────────────────────────────────────────────

echo "::notice::Starting RAG API..."
run_bg ragapi \
  singularity exec \
    --cleanenv \
    --writable-tmpfs \
    --pwd /app \
    --env-file "$CLEAN_ENV" \
    --env DB_HOST=localhost \
    --env DB_PORT=$PG_PORT \
    --env POSTGRES_DB=mydatabase \
    --env POSTGRES_USER=myuser \
    --env POSTGRES_PASSWORD=mypassword \
    --env RAG_PORT=$RAG_PORT \
    "$SIF/rag_api.sif" \
    python main.py

wait_for_port $RAG_PORT "RAG API"

# ── LibreChat ─────────────────────────────────────────────────────────────────

echo "::notice::Starting LibreChat..."
run_bg librechat \
  singularity exec \
    --writable-tmpfs \
    --pwd /app \
    --bind "$BASE/.env:/app/.env" \
    --bind "$BASE/images:/app/client/public/images" \
    --bind "$BASE/uploads:/app/uploads" \
    --bind "$BASE/logs:/app/logs" \
    --env HOST=0.0.0.0 \
    --env PORT=$service_port \
    --env DOMAIN_SERVER=http://localhost:$service_port \
    --env MONGO_URI=mongodb://localhost:$MONGODB_PORT/LibreChat \
    --env MEILI_HOST=http://localhost:$MEILI_PORT \
    --env RAG_API_URL=http://localhost:$RAG_PORT \
    "$SIF/librechat.sif" \
    npm run backend

wait_for_port $service_port "LibreChat"

echo "::endgroup::"

# ── Done ──────────────────────────────────────────────────────────────────────

echo "::notice::All services running. PIDs in $PID_DIR/"
echo "::notice::Logs in $LOG_DIR/"
echo "::notice::Stop script: singularity-stop.sh"

wait
