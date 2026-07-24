#!/usr/bin/env bash
# start-template-v4.sh — Langflow via Singularity (runs on the service node)
#
# Uses the SIF images downloaded by controller-v4.sh. Optionally launches an
# HFTEI embeddings server for RAG, then Langflow and the OpenAI-compatible
# Langflow proxy, and registers the Langflow endpoint.

set -o pipefail
set -x

################################################################################
# Required Environment Variables:
#   - service_parent_install_dir: Installation directory
#   - PW_PARENT_JOB_DIR:          Job working directory
#
# Optional Environment Variables:
#   - service_langflow_data_dir:        Langflow data directory
#                                       (default: ${HOME}/pw/.langflow)
#   - service_langflow_config_dir:      LANGFLOW_CONFIG_DIR inside container;
#                                       custom components in <dir>/components/ are
#                                       auto-discovered (default: same as data dir)
#   - service_langflow_components_path: LANGFLOW_COMPONENTS_PATH — additional
#                                       custom components directory; bind-mounted
#                                       only when set (default: unset)
#   - service_langflow_database_url:    LANGFLOW_DATABASE_URL; for SQLite the
#                                       database dir is bind-mounted automatically
#                                       (default: sqlite inside config dir)
#   - langflow_rag_db_dir:              Host directory with the RAG vector
#                                       database; mounted at /data inside the
#                                       Langflow container (default: unset)
#   - langflow_enable_hftei:            "true" → start the HFTEI embeddings
#                                       server used by the RAG flows
#   - langflow_hftei_model_dir:         Host directory with the embedding model
#                                       weights; mounted at /models/mpnet-v2 in
#                                       the HFTEI container
################################################################################

if [ -n "${service_parent_install_dir}" ]; then
    container_sif=${service_parent_install_dir}/containers/langflow.sif
    if ! [ -f "${container_sif}" ] && ! [ -w "${service_parent_install_dir}" ]; then
        echo "::warning::container_sif ${container_sif} does not exist and no write permission to ${service_parent_install_dir}. Resetting to ${HOME}/pw/software."
        service_parent_install_dir=${HOME}/pw/software
    fi
else
    service_parent_install_dir=${HOME}/pw/software
fi

container_sif=${service_parent_install_dir}/containers/langflow.sif
LANGFLOW_DATA_DIR="${service_langflow_data_dir:-${HOME}/pw/.langflow}"
LANGFLOW_CONFIG_DIR="${service_langflow_config_dir:-${LANGFLOW_DATA_DIR}}"

service_port=$(pw agent open-port) || { echo "::error title=Error::Failed to allocate Langflow port"; exit 1; }

echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh

# The LibreChat job waits for this file to locate the Langflow node; scheduled
# runs get it from the sbatch/qsub headers, unscheduled runs need it here.
hostname > HOSTNAME

if ! [ -f "${container_sif}" ]; then
    echo "::error title=Error::Langflow container not found at ${container_sif}. Run controller first."
    exit 1
fi

# ── Load singularity/apptainer ─────────────────────────────────────────────────
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

# Unset host env vars that can corrupt the container's Python runtime.
# On Cray EX and similar HPC systems, LD_LIBRARY_PATH carries PE paths that
# cause Python to load incompatible native libraries.
unset PYTHONPATH PYTHONHOME PERL5LIB PERLLIB PERL5OPT PYTHONSTARTUP LD_LIBRARY_PATH

# SSL_CERT_FILE on RHEL/EL hosts points to /etc/pki/ca-trust/... which does
# not exist inside the Debian-based Langflow container. Override it to the
# Debian CA bundle so HTTPS calls (telemetry, component downloads) work.
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

mkdir -p "${LANGFLOW_DATA_DIR}"

# Config dir — create and bind only when it differs from the data dir
if [ "${LANGFLOW_CONFIG_DIR}" != "${LANGFLOW_DATA_DIR}" ]; then
    mkdir -p "${LANGFLOW_CONFIG_DIR}"
    chmod 777 "${LANGFLOW_CONFIG_DIR}" -Rf || true
fi

# ── SIF or sandbox fallback ────────────────────────────────────────────────────
# Some nodes cannot mount SIF images (no squashfs/FUSE support). Probe on this
# node — the one that runs the service — and fall back to unpacking a sandbox
# once (offline-safe: pure local unpack). The same probe result applies to
# every container on this node.
resolve_container_ref() {
    # $1 = SIF path, $2 = sandbox dir; prints the reference to run
    if [ "${use_sandbox}" != "true" ]; then
        echo "$1"
        return
    fi
    if ! [ -d "$2" ]; then
        singularity build --fakeroot --force --sandbox "$2" "$1" >&2 || return 1
    fi
    echo "$2"
}

if singularity exec "${container_sif}" /bin/true > /dev/null 2>&1; then
    use_sandbox=false
else
    echo "::notice::SIF mounting not supported on this node; using sandbox fallback"
    export SINGULARITY_TMPDIR=${HOME}/.singularity_tmp
    export SINGULARITY_CACHEDIR=${HOME}/.singularity_cache
    mkdir -p $SINGULARITY_TMPDIR $SINGULARITY_CACHEDIR
    use_sandbox=true
fi

container_ref=$(resolve_container_ref "${container_sif}" "${service_parent_install_dir}/containers/langflow-sandbox") || {
    echo "::error title=Error::Failed to build Langflow sandbox from ${container_sif}"
    exit 1
}

# Build optional --bind / --env arrays for the singularity exec call
EXTRA_BINDS=()
EXTRA_ENVS=()

# LANGFLOW_CONFIG_DIR bind (always; duplicate bind with data dir is harmless)
EXTRA_BINDS+=(--bind "${LANGFLOW_CONFIG_DIR}:${LANGFLOW_CONFIG_DIR}")

# Optional: custom components path
if [ -n "${service_langflow_components_path}" ]; then
    mkdir -p "${service_langflow_components_path}"
    chmod 777 "${service_langflow_components_path}" || true
    EXTRA_BINDS+=(--bind "${service_langflow_components_path}:${service_langflow_components_path}")
    EXTRA_ENVS+=(--env "LANGFLOW_COMPONENTS_PATH=${service_langflow_components_path}")
fi

# Optional: explicit database URL; bind the parent directory for SQLite absolute paths
if [ -n "${service_langflow_database_url}" ]; then
    if [[ "${service_langflow_database_url}" == sqlite:////* ]]; then
        db_path="${service_langflow_database_url#sqlite:///}"   # strips sqlite:/// → /abs/path.db
        db_dir="$(dirname "${db_path}")"
        mkdir -p "${db_dir}"
        chmod 777 "${db_dir}" || true
        EXTRA_BINDS+=(--bind "${db_dir}:${db_dir}")
    fi
    EXTRA_ENVS+=(--env "LANGFLOW_DATABASE_URL=${service_langflow_database_url}")
fi

# Optional: RAG vector database, mounted where the RAG flows expect it (/data).
# The proxy flow configs reference corpora by table name inside this directory.
if [ -n "${langflow_rag_db_dir}" ]; then
    if ! [ -d "${langflow_rag_db_dir}" ]; then
        echo "::error title=RAG database not found::RAG Database Directory '${langflow_rag_db_dir}' does not exist on the Langflow host ($(hostname))."
        exit 1
    fi
    EXTRA_BINDS+=(--bind "${langflow_rag_db_dir}:/data")
    echo "::notice::RAG database ${langflow_rag_db_dir} mounted at /data"
fi

# Per-job /tmp prevents cross-user permission conflicts on shared nodes
mkdir -p "$PWD/container_tmp"
echo "rm -rf $PWD/container_tmp" >> cancel.sh

# ── Optional: auto-import bundled flows ────────────────────────────────────────
# When the combined LibreChat + Langflow workflow ships flow JSONs alongside the
# proxy code (${langflow_proxy_dir}/flows), bind that directory into the container
# and let Langflow import them on startup via LANGFLOW_LOAD_FLOWS_PATH. Imported
# flows are upserted (idempotent) and owned by the superuser, so they get a
# non-null user_id and the proxy discovers them as selectable models.
if [ "${langflow_enable_proxy}" = "true" ] && [ -n "${langflow_proxy_dir}" ]; then
    # Import the user's own flows from ${langflow_proxy_dir}/flows. Optionally also import
    # the flows bundled in this repo (langflow-singularity/flows, e.g. chatbot,
    # rag_chatbot) — only when ${langflow_import_bundled_flows} is true (on for
    # general-all, off for hsp-all).
    # Everything is merged into one directory so a single LANGFLOW_LOAD_FLOWS_PATH imports it;
    # imported flows are owned by the superuser, so the proxy discovers them as models.
    proxy_flows_import_dir="${PW_PARENT_JOB_DIR}/langflow/import-flows"
    repo_flows_dir="${PW_PARENT_JOB_DIR}/langflow-singularity/flows"
    mkdir -p "${proxy_flows_import_dir}"
    [ -d "${langflow_proxy_dir}/flows" ] && cp -f "${langflow_proxy_dir}/flows/"*.json "${proxy_flows_import_dir}/" 2>/dev/null || true
    if [ "${langflow_import_bundled_flows}" = "true" ] && [ -d "${repo_flows_dir}" ]; then
        cp -f "${repo_flows_dir}/"*.json "${proxy_flows_import_dir}/" 2>/dev/null || true
        echo "::notice::Importing bundled repo flows from ${repo_flows_dir}"
    fi
    if ls "${proxy_flows_import_dir}/"*.json >/dev/null 2>&1; then
        EXTRA_BINDS+=(--bind "${proxy_flows_import_dir}:${proxy_flows_import_dir}")
        EXTRA_ENVS+=(--env "LANGFLOW_LOAD_FLOWS_PATH=${proxy_flows_import_dir}")
        EXTRA_ENVS+=(--env "LANGFLOW_LOAD_FLOWS_OVERWRITE_ON_NAME_MATCH=true")
        echo "::notice::Auto-importing Langflow flows from ${proxy_flows_import_dir}"
    fi

    # ── ACTIVATE platform credentials for OpenAI-compatible flows ───────────────
    # A flow whose Language Model node uses the "OpenAI Compatible API" provider
    # reads its key from ~/.secrets/<PROVIDER>_API_KEY (OPENAI_COMPATIBLE_API_API_KEY).
    # Publish the platform key there and bind ~/.secrets into the container so the
    # flow can call https://${PW_PLATFORM_HOST}/api/openai/v1 with the platform key.
    # Platform org models (org:*) also require an X-Allocation header, which the flow
    # forwards from $PW_ALLOCATION — discover one here. No-op for the GenAI.mil flow.
    if [ -n "${PW_API_KEY}" ]; then
        { set +x; } 2>/dev/null   # do not trace the platform key
        mkdir -p "${HOME}/.secrets"
        printf '%s' "${PW_API_KEY}" > "${HOME}/.secrets/OPENAI_COMPATIBLE_API_API_KEY"
        chmod 600 "${HOME}/.secrets/OPENAI_COMPATIBLE_API_API_KEY" 2>/dev/null || true
        _plat="${PW_PLATFORM_HOST#https://}"
        pw_alloc=""
        for _try in 1 2 3; do
            pw_alloc=$(curl -s -m 15 "https://${_plat}/api/allocations" \
                -H "Authorization: Bearer ${PW_API_KEY}" 2>/dev/null | python3 -c '
import sys, json
try:
    a = json.load(sys.stdin)
    names = [x.get("name", "") for x in a if x.get("name")]
    print(next((n for n in names if "LLM" in n), names[0] if names else ""))
except Exception:
    print("")' 2>/dev/null)
            [ -n "${pw_alloc}" ] && break
            sleep 3
        done
        set -x
        EXTRA_BINDS+=(--bind "${HOME}/.secrets:${HOME}/.secrets")
        if [ -n "${pw_alloc}" ]; then
            EXTRA_ENVS+=(--env "PW_ALLOCATION=${pw_alloc}")
            echo "::notice::Platform X-Allocation for org models: ${pw_alloc}"
        else
            echo "::notice::No platform allocation discovered (org models may need X-Allocation)"
        fi
    fi
fi

# ── Optional: HFTEI embeddings server ──────────────────────────────────────────
# Serves the embedding model the RAG flows use to vectorize queries. Runs on a
# runtime-allocated port; the proxy flow configs reference it with the
# ${HFTEI_PORT} placeholder, substituted into the proxy config below.
if [ "${langflow_enable_hftei}" = "true" ]; then
    hftei_sif=${service_parent_install_dir}/containers/hftei-cpu-1.6.0.sif
    if ! [ -f "${hftei_sif}" ]; then
        echo "::error title=Error::HFTEI container not found at ${hftei_sif}. Run controller first."
        exit 1
    fi
    if [ -z "${langflow_hftei_model_dir}" ] || ! [ -d "${langflow_hftei_model_dir}" ]; then
        echo "::error title=HFTEI model not found::HFTEI Model Directory '${langflow_hftei_model_dir:-<empty>}' does not exist on the Langflow host ($(hostname)). Stage the embedding model weights there, or disable HFTEI."
        exit 1
    fi
    hftei_ref=$(resolve_container_ref "${hftei_sif}" "${service_parent_install_dir}/containers/hftei-sandbox") || {
        echo "::error title=Error::Failed to build HFTEI sandbox from ${hftei_sif}"
        exit 1
    }
    hftei_port=$(pw agent open-port) || { echo "::error title=Error::Failed to allocate HFTEI port"; exit 1; }

    echo "::group::Starting HFTEI embeddings server"
    echo "::notice::Model: ${langflow_hftei_model_dir} → /models/mpnet-v2, port ${hftei_port}"
    singularity exec \
        --bind "${langflow_hftei_model_dir}:/models/mpnet-v2" \
        "${hftei_ref}" \
        text-embeddings-router \
            --hostname 0.0.0.0 \
            --port "${hftei_port}" \
            --model-id /models/mpnet-v2 \
            --pooling mean \
            --tokenization-workers 4 \
        > hftei.log 2>&1 &

    echo "kill $! #hftei" >> cancel.sh
    tail -f hftei.log &
    echo "kill $! #hftei-logs" >> cancel.sh
    echo "::endgroup::"
fi

# ── Start Langflow ─────────────────────────────────────────────────────────────
echo "::group::Starting Langflow"
echo "::notice::Port: ${service_port}"
echo "::notice::Data directory: ${LANGFLOW_DATA_DIR}"
echo "::notice::Config directory: ${LANGFLOW_CONFIG_DIR}"
echo "::notice::Container: ${container_ref}"
[ -n "${service_langflow_components_path}" ] && echo "::notice::Components path: ${service_langflow_components_path}"
[ -n "${service_langflow_database_url}" ]    && echo "::notice::Database URL: ${service_langflow_database_url}"

singularity exec \
    --writable-tmpfs \
    --bind "${LANGFLOW_DATA_DIR}:${LANGFLOW_DATA_DIR}" \
    --bind "$PWD/container_tmp:/tmp" \
    "${EXTRA_BINDS[@]}" \
    --env LANGFLOW_CONFIG_DIR="${LANGFLOW_CONFIG_DIR}" \
    "${EXTRA_ENVS[@]}" \
    --env DO_NOT_TRACK="true" \
    --env LANGFLOW_DO_NOT_TRACK="true" \
    --env LANGFLOW_ALEMBIC_LOG_TO_STDOUT="true" \
    --env LANGFLOW_SKIP_AUTH_AUTO_LOGIN="true" \
    "${container_ref}" \
    langflow run \
        --host 0.0.0.0 \
        --port "${service_port}" \
        --no-open-browser \
        --log-level info \
    > langflow.log 2>&1 &

langflow_pid=$!
echo "kill ${langflow_pid} #langflow" >> cancel.sh
echo "::endgroup::"

# ── Tail logs so platform captures startup output ──────────────────────────────
echo "::group::Langflow logs"
tail -f langflow.log &
logs_pid=$!
echo "kill ${logs_pid} #langflow-logs" >> cancel.sh
echo "::endgroup::"

echo "::notice::Langflow → http://localhost:${service_port}"

# ── Optional: OpenAI-compatible Langflow proxy ──────────────────────────────────
# When ${langflow_proxy_dir} is set, launch the proxy co-located with Langflow so a
# LibreChat user can pick each Langflow flow as a model. The proxy reads the
# Langflow DB directly (flow discovery) and forwards chat turns to Langflow's run
# API on localhost. Auth, when LANGFLOW_API_KEY is set, is shared with LibreChat.
#
# If the proxy is enabled, it MUST be launchable here — otherwise LANGFLOW_PROXY_PORT is
# never published and LibreChat waits forever. The controller already fails fast on a
# missing proxy dir; re-check (defense in depth) and error rather than silently skip.
if [ "${langflow_enable_proxy}" = "true" ] && { [ -z "${langflow_proxy_dir}" ] || [ ! -d "${langflow_proxy_dir}/langflow_proxy" ]; }; then
    echo "::error title=Langflow proxy code not found::'Start Langflow Proxy?' is enabled but the langflow_proxy package was not found at Langflow Proxy Path '${langflow_proxy_dir:-<empty>}' on the Langflow host ($(hostname)). Stage the proxy code there, or disable the proxy."
    exit 1
fi
if [ "${langflow_enable_proxy}" = "true" ] && [ -n "${langflow_proxy_dir}" ] && [ -d "${langflow_proxy_dir}/langflow_proxy" ]; then
    echo "::group::Starting Langflow proxy"
    # Allocate a port dynamically and publish it to the shared job dir so the
    # (parallel) LibreChat job can read it and register the proxy endpoint.
    proxy_port=$(pw agent open-port)
    [ -n "${proxy_port}" ] && echo "${proxy_port}" > "${PW_PARENT_JOB_DIR}/LANGFLOW_PROXY_PORT"
    echo "::notice::Langflow proxy port ${proxy_port} → ${PW_PARENT_JOB_DIR}/LANGFLOW_PROXY_PORT"

    # Resolve the Langflow DB file the proxy queries for flows. SQLAlchemy URLs use
    # four slashes for an absolute path (sqlite:////abs/x.db → /abs/x.db); strip the
    # sqlite:/// prefix exactly as the proxy's own DB layer does.
    if [[ "${service_langflow_database_url}" == sqlite:///* ]]; then
        proxy_db_path="${service_langflow_database_url#sqlite:///}"   # sqlite:////abs → /abs
        case "${proxy_db_path}" in /*) : ;; *) proxy_db_path="/${proxy_db_path}" ;; esac
        # Collapse duplicate slashes: the default URL sqlite:////${HOME}/... yields
        # //home/... (${HOME} already starts with /), and sqlite3's file: URI would
        # otherwise read the first path segment ("home") as an authority and fail.
        proxy_db_path=$(printf '%s' "${proxy_db_path}" | sed 's#/\{2,\}#/#g')
    else
        proxy_db_path="${LANGFLOW_CONFIG_DIR}/langflow.db"
    fi

    proxy_config="${PW_PARENT_JOB_DIR}/langflow/proxy-config.yaml"

    # Optional API-key auth, shared with the LibreChat endpoint via LANGFLOW_API_KEY.
    proxy_api_key_line=""
    if [ -n "${LANGFLOW_API_KEY}" ]; then
        proxy_key_file="${PW_PARENT_JOB_DIR}/langflow/.proxy_api_key"
        printf '%s' "${LANGFLOW_API_KEY}" > "${proxy_key_file}"
        chmod 600 "${proxy_key_file}" || true
        proxy_api_key_line="  api_key_file: \"${proxy_key_file}\""
    fi

    cat > "${proxy_config}" <<PROXYCFG
proxy:
  host: 0.0.0.0
  port: ${proxy_port}
${proxy_api_key_line}
langflow:
  host: 127.0.0.1
  port: ${service_port}
  database_path: "${proxy_db_path}"
PROXYCFG

    # Append an optional user-provided top-level `flows:` block (per-flow model
    # routing). Looked up at ${langflow_proxy_flows_file} first, else flows.yaml
    # next to the proxy code. Without it, every flow is exposed with defaults.
    proxy_flows_file=""
    if [ -n "${langflow_proxy_flows_file}" ] && [ -s "${langflow_proxy_flows_file}" ]; then
        proxy_flows_file="${langflow_proxy_flows_file}"
    elif [ -s "${langflow_proxy_dir}/flows.yaml" ]; then
        proxy_flows_file="${langflow_proxy_dir}/flows.yaml"
    fi
    [ -n "${proxy_flows_file}" ] && cat "${proxy_flows_file}" >> "${proxy_config}"

    # The flows file cannot know the runtime-allocated HFTEI port, so it
    # references it as ${HFTEI_PORT} (e.g. base_url: "http://localhost:${HFTEI_PORT}").
    if [ -n "${hftei_port:-}" ]; then
        sed -i "s/\${HFTEI_PORT}/${hftei_port}/g" "${proxy_config}"
    fi

    # Run the proxy with the Langflow container's Python: it ships every proxy
    # dependency, so no host venv (or host Python version) is involved. Launch
    # uvicorn directly (not bin/langflow_proxy) so a not-yet-created Langflow DB
    # doesn't trip the strict pre-flight validator; the proxy discovers flows
    # lazily and re-reads its config on every request.
    singularity exec \
        --bind "${langflow_proxy_dir}:${langflow_proxy_dir}" \
        --bind "${PW_PARENT_JOB_DIR}:${PW_PARENT_JOB_DIR}" \
        --bind "$(dirname "${proxy_db_path}"):$(dirname "${proxy_db_path}")" \
        --env APP_CONFIG_PATH="${proxy_config}" \
        --env PYTHONPATH="${langflow_proxy_dir}" \
        "${container_ref}" \
        /app/.venv/bin/python -m uvicorn langflow_proxy.main:app \
            --host 0.0.0.0 --port "${proxy_port}" \
        > langflow-proxy.log 2>&1 &
    proxy_pid=$!
    echo "kill ${proxy_pid} #langflow-proxy" >> cancel.sh
    echo "::notice::Langflow proxy → http://localhost:${proxy_port}/v1 (pid ${proxy_pid})"
    tail -f langflow-proxy.log &
    echo "kill $! #langflow-proxy-logs" >> cancel.sh

    # Warm up each flow once in the background: the first request after a
    # cold start can hit a Python import deadlock inside Langflow
    # (concurrent langchain imports), so absorb it here instead of on a
    # user-facing request.
    (
        auth_args=()
        [ -n "${LANGFLOW_API_KEY}" ] && auth_args=(-H "Authorization: Bearer ${LANGFLOW_API_KEY}")
        models=""
        for _ in $(seq 1 60); do
            models=$(curl -s -m 5 "${auth_args[@]}" "localhost:${proxy_port}/v1/models" \
                | python3 -c 'import sys,json; print(" ".join(m["id"] for m in json.load(sys.stdin).get("data",[])))' 2>/dev/null)
            [ -n "${models}" ] && break
            sleep 10
        done
        for model in ${models}; do
            curl -s -m 300 "${auth_args[@]}" -H 'Content-Type: application/json' \
                -d "{\"model\": \"${model}\", \"stream\": false, \"max_tokens\": 1, \"messages\": [{\"role\": \"user\", \"content\": \"ping\"}]}" \
                "localhost:${proxy_port}/v1/chat/completions" > /dev/null
            echo "warmed up ${model}"
        done
    ) > warmup.log 2>&1 &
    echo "::endgroup::"
fi

# The endpoint is the foreground keep-alive: it serves the already-listening
# Langflow port and tears the session down when it exits.
# set -e would exit on a non-zero pw exit before the fail-loud block runs
set +e
pw endpoints http ${pw_endpoints_args} ${service_port}

if [ $? -ne 0 ]; then
    echo "::error title=Error::pw endpoints command failed"
    # Fail loud: without this, wait_for_endpoint polls forever for an endpoint
    # that will never register
    pw workflows runs cancel ${PW_RUN_SLUG}
    exit 1
fi
