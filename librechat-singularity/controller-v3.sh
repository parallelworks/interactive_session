set -o pipefail
set -x

source ${PW_PARENT_JOB_DIR}/tools/oras/libs.sh

# Unset any workflow env vars that arrived as empty strings so they don't
# shadow values already in .env.example or other defaults.
for _var in PW_API_KEY GENAI_MIL_API_KEY JWT_SECRET JWT_REFRESH_SECRET LIBRECHAT_API_KEY LANGFLOW_API_KEY; do
    [ -z "${!_var}" ] && unset "$_var"
done
unset _var

if (( ${PW_WORKFLOW_STEP_CURRENT_RETRY:-0} >= 1 )); then
    service_parent_install_dir=${HOME}/pw/software
    echo "export service_parent_install_dir=${service_parent_install_dir}" >> inputs.sh
    echo "::warning::Retry attempt ${PW_WORKFLOW_STEP_CURRENT_RETRY}/${PW_WORKFLOW_STEP_MAX_RETRIES} — switching install directory to ${service_parent_install_dir}"
fi

if [ -n "${service_parent_install_dir}" ]; then
    container_dir=${service_parent_install_dir}/containers/librechat
    if ! [ -d "${container_dir}" ] && ! [ -w "${service_parent_install_dir}" ]; then
        echo "::warning::container_dir ${container_dir} does not exist and no write permission to ${service_parent_install_dir}. Resetting to ${HOME}/pw/software."
        service_parent_install_dir=${HOME}/pw/software
    fi
else
    service_parent_install_dir=${HOME}/pw/software
fi

mkdir -p ${service_parent_install_dir}/containers ${service_parent_install_dir}/tools
chmod a+rX ${service_parent_install_dir}/containers ${service_parent_install_dir}/tools

container_dir=${service_parent_install_dir}/containers/librechat
container_tar=${container_dir}-sifs.tar


# Download the container only when it is not already present (idempotent)
if ! [ -d "${container_dir}" ]; then
    echo "::group::LibreChat Singularity Container Download"
    echo "::notice::Using GitHub registry to download file"
    oras_pull_file ghcr.io/parallelworks/librechat:v1.0 librechat-sifs.tar ${container_tar}
    if [ ! -s ${container_tar} ]; then
        echo "::error title=Error::Failed to download file ${container_tar}"
        exit 1
    fi
    mkdir -p ${container_dir}
    if ! tar xf ${container_tar} -C ${container_dir}; then
        echo "::error title=Error::Failed to extract ${container_tar}"
        exit 1
    fi
    chmod -R a+rX ${container_dir}
    rm ${container_tar}
    echo "::endgroup::"
fi


REPO="https://github.com/danny-avila/LibreChat.git"
DIR="${librechat_dir:-${HOME}/pw/LibreChat}"

# ── Clone or pull ─────────────────────────────────────────────────────────────

mkdir -p "$(dirname "$DIR")"
if [ ! -d "$DIR/.git" ]; then
  echo "::notice::Cloning LibreChat..."
  git clone "$REPO" "$DIR"
else
  echo "::notice::Pulling latest changes..."
  git -C "$DIR" pull
fi

# ── Set up .env ───────────────────────────────────────────────────────────────
cp "$DIR/.env.example" "$DIR/.env"

if [[ "${domain_client}" == "ACTIVATE" ]]; then
    DOMAIN_CLIENT="https://${PW_PLATFORM_HOST}${basepath}"
    sed -i "s|^DOMAIN_CLIENT=.*|DOMAIN_CLIENT=$DOMAIN_CLIENT|" "$DIR/.env"
    echo "::notice::DOMAIN_CLIENT set to $DOMAIN_CLIENT"
fi



# ── LibreChat YAML config ─────────────────────────────────────────────────────
# This is only used if ${librechat_config} is unset

# Set/replace key=value pairs idempotently (upsert: replace if present, append if absent)
_upsert() {
    local key="$1" val="$2" file="$3"
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$file"
    else
        echo "${key}=${val}" >> "$file"
    fi
}

[ -n "${GENAI_MIL_API_KEY}" ] && _upsert GENAI_MIL_API_KEY "${GENAI_MIL_API_KEY}" "$DIR/.env"
[ -n "${PW_API_KEY}" ]        && _upsert PW_API_KEY         "${PW_API_KEY}"         "$DIR/.env"

# Registration is enabled by default so users can create their first account
_upsert ALLOW_REGISTRATION      true  "$DIR/.env"
_upsert ALLOW_SOCIAL_LOGIN      false "$DIR/.env"
_upsert ALLOW_SOCIAL_REGISTRATION false "$DIR/.env"

[ -n "${JWT_SECRET}" ]         && _upsert JWT_SECRET         "${JWT_SECRET}"         "$DIR/.env"
[ -n "${JWT_REFRESH_SECRET}" ] && _upsert JWT_REFRESH_SECRET "${JWT_REFRESH_SECRET}" "$DIR/.env"

# Generate random secrets when not provided — LibreChat refuses to start without them
for _var in JWT_SECRET JWT_REFRESH_SECRET; do
    _current=$(grep "^${_var}=" "$DIR/.env" 2>/dev/null | cut -d= -f2-)
    if [ -z "$_current" ]; then
        _upsert "${_var}" "$(openssl rand -hex 32)" "$DIR/.env"
        echo "::notice::Generated random ${_var}"
    fi
done
unset _var _current



cat > "$DIR/librechat.yaml" <<YAML_EOF
version: 1.1.4
cache: true

endpoints:
  custom:
    - name: "GenAI MIL"
      apiKey: "\${GENAI_MIL_API_KEY}"
      baseURL: "https://api.genai.mil/v1"
      models:
        default: ["gemini-3-flash-preview"]
        fetch: true
      titleConvo: true
      titleModel: "gemini-2.5-flash"
      summarize: false
      displayLabelEnabled: true
    - name: "ACTIVATE"
      apiKey: "\${PW_API_KEY}"
      baseURL: "https://${PW_PLATFORM_HOST}/api/openai/v1"
      models:
        default: [""]
        fetch: true
      titleConvo: true
      summarize: false
      displayLabelEnabled: true
YAML_EOF
echo "::notice::LibreChat YAML config written to $DIR/librechat.yaml"

# ── Optional: Langflow proxy endpoint ──────────────────────────────────────────
# When the combined workflow runs the Langflow proxy (${langflow_proxy_dir} set),
# register it as an extra custom endpoint so users can pick each Langflow flow as a
# model. The proxy is co-located on the service host, reachable at localhost:<port>.
# Appended as another item under endpoints.custom (same 4-space indent).
# Only effective when LibreChat uses this generated config (librechat_config unset).
if [ "${langflow_enable_proxy}" = "true" ] && [ -n "${langflow_proxy_dir}" ]; then
    # The proxy port is allocated by the (parallel) Langflow job and published to
    # ${PW_PARENT_JOB_DIR}/LANGFLOW_PROXY_PORT on the *Langflow* host. When Langflow
    # shares this host (langflow_same_host=true) we read it from the local, shared
    # job dir. When Langflow runs on a different resource we fetch it over
    # `pw ssh <langflow_resource>` — the parent job dir path is identical on both
    # hosts (same user/home/run). Either way we mirror the value to the local job
    # dir so the start script can `pw forward` the port. Bounded wait; skip
    # gracefully if it never appears so LibreChat still starts.
    _port_file="${PW_PARENT_JOB_DIR}/LANGFLOW_PROXY_PORT"
    _retries=40
    langflow_proxy_port=""
    while [ -z "${langflow_proxy_port}" ] && [ "${_retries}" -gt 0 ]; do
        if [ "${langflow_same_host}" = "true" ] || [ -z "${langflow_resource_name}" ]; then
            [ -s "${_port_file}" ] && langflow_proxy_port=$(tr -d '[:space:]' < "${_port_file}")
        else
            langflow_proxy_port=$(pw ssh "${langflow_resource_name}" "cat '${_port_file}' 2>/dev/null" 2>/dev/null | tr -d '[:space:]')
        fi
        if [ -z "${langflow_proxy_port}" ]; then
            echo "::notice::Waiting for Langflow proxy port (host=${langflow_resource_name:-local}) — retries left: ${_retries}"
            sleep 15
            _retries=$(( _retries - 1 ))
        fi
    done
    if [ -n "${langflow_proxy_port}" ]; then
        # Mirror the port to the local job dir so the start script's pw forward
        # (cross-host case) can read it without another pw ssh round-trip.
        echo "${langflow_proxy_port}" > "${_port_file}"
        if [ -n "${LANGFLOW_API_KEY}" ]; then
            _upsert LANGFLOW_API_KEY "${LANGFLOW_API_KEY}" "$DIR/.env"
            _proxy_api_key='${LANGFLOW_API_KEY}'   # resolved from .env by LibreChat at runtime
        else
            _proxy_api_key='langflow-proxy'        # placeholder; proxy auth is disabled
        fi
        cat >> "$DIR/librechat.yaml" <<YAML_EOF
    - name: "Langflow"
      apiKey: "${_proxy_api_key}"
      baseURL: "http://localhost:${langflow_proxy_port}/v1"
      models:
        default: ["langflow"]
        fetch: true
      titleConvo: true
      summarize: false
      displayLabelEnabled: true
YAML_EOF
        echo "::notice::Added Langflow proxy endpoint (http://localhost:${langflow_proxy_port}/v1) to librechat.yaml"
    else
        echo "::warning::Langflow proxy port not found (host=${langflow_resource_name:-local}) after waiting — LibreChat will start without the Langflow endpoint."
    fi
fi