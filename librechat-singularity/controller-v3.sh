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

[ -n "${GENAI_MIL_API_KEY}" ] && echo "GENAI_MIL_API_KEY=${GENAI_MIL_API_KEY}" >> "$DIR/.env"
[ -n "${PW_API_KEY}" ]     && echo "PW_API_KEY=${PW_API_KEY}"           >> "$DIR/.env"

[ -n "${JWT_SECRET}" ]         && { grep -q '^JWT_SECRET=' "$DIR/.env" \
    && sed -i "s|^JWT_SECRET=.*|JWT_SECRET=${JWT_SECRET}|" "$DIR/.env" \
    || echo "JWT_SECRET=${JWT_SECRET}" >> "$DIR/.env"; }
[ -n "${JWT_REFRESH_SECRET}" ] && { grep -q '^JWT_REFRESH_SECRET=' "$DIR/.env" \
    && sed -i "s|^JWT_REFRESH_SECRET=.*|JWT_REFRESH_SECRET=${JWT_REFRESH_SECRET}|" "$DIR/.env" \
    || echo "JWT_REFRESH_SECRET=${JWT_REFRESH_SECRET}" >> "$DIR/.env"; }



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