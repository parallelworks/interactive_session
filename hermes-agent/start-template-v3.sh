################################################################################
# Interactive Session Starter - Hermes Agent (NousResearch Hermes)
#
# Purpose: run the real Hermes Agent as an OpenAI-compatible chat model.
#   1. Point Hermes' "brain" at the ACTIVATE platform LLM endpoint.
#   2. Start Hermes' built-in OpenAI API server (`hermes gateway`, api_server
#      platform) on a PRIVATE loopback port.
#   3. Front it with a tiny key-injecting proxy on ${service_port} (0.0.0.0) so
#      the platform session tunnel can reach it without knowing the api key.
#   The session is declared openAI:true, so it registers as a chat *provider*.
# Runs on: cluster login node (scheduler:false)
# Called by: session_runner, after inputs.sh is sourced and ${service_port} is set
#
# Variables from inputs.sh:
#   service_name        service dir under the job dir (hermes-agent)
#   service_model       brain model id (e.g. org:glm/glm-5.1)
#   service_allocation  X-Allocation for org:* models
#   service_port        tunnel-facing port (set by session_runner)
# Brain credential = runtime PW_API_KEY (exported by the workflow's env: block);
# it is written only to the per-session Hermes config in the job dir, never to
# inputs.sh, and is scrubbed by cancel.sh.
################################################################################
set -x

AGENT_DIR="${PW_PARENT_JOB_DIR}/${service_name:-hermes-agent}"
export PATH="${HOME}/.local/bin:${HOME}/pw:${PATH}"   # hermes + pw on PATH

# Per-session Hermes home: config (incl. the brain key) and data live in the job
# dir, isolated per run — not in ${HOME}/.hermes.
export HERMES_HOME="${PW_PARENT_JOB_DIR}/hermes-home"
mkdir -p "${HERMES_HOME}"

# Brain -> ACTIVATE platform OpenAI-compatible endpoint. Hermes' "custom" provider
# reads the bearer from model.api_key (NOT from OPENAI_API_KEY env), and org:*
# models need the X-Allocation header, sent via default_headers.
cat > "${HERMES_HOME}/config.yaml" <<EOF
model:
  default: "${service_model:-org:glm/glm-5.1}"
  provider: "custom"
  base_url: "https://${PW_PLATFORM_HOST}/api/openai/v1"
  api_key: "${PW_API_KEY}"
  default_headers:
    X-Allocation: "${service_allocation:-Private LLM Group}"
EOF
chmod 600 "${HERMES_HOME}/config.yaml"

# Hermes' OpenAI api_server requires a key even on loopback; the platform tunnel
# forwards no upstream auth, so we keep the api_server private and inject the key
# in the proxy. Bind it on a private loopback port derived from service_port.
hermes_api_port=$(( ${service_port} + 1 ))
api_key="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
export API_SERVER_ENABLED=true
export API_SERVER_HOST=127.0.0.1
export API_SERVER_PORT="${hermes_api_port}"
export API_SERVER_KEY="${api_key}"

# Unattended service: there is no human approval channel over the chat API, so
# auto-approve tool/command execution. Without this, the agent hits Hermes'
# dangerous-command approval gate, stalls, and the chat reports "not reachable".
# (The chat provider itself is the access boundary; see the README security note.)
export HERMES_YOLO_MODE=1

gw_log="${PW_PARENT_JOB_DIR}/hermes-gateway.out"
proxy_log="${PW_PARENT_JOB_DIR}/auth-proxy.out"

# 1) Hermes gateway (serves the OpenAI api_server on 127.0.0.1:${hermes_api_port})
hermes gateway > "${gw_log}" 2>&1 &
gw_pid=$!

# 2) Key-injecting proxy: tunnel-facing 0.0.0.0:${service_port} -> api_server
python3 "${AGENT_DIR}/auth_proxy.py" \
    --listen "0.0.0.0:${service_port}" \
    --upstream "127.0.0.1:${hermes_api_port}" \
    --bearer "${api_key}" > "${proxy_log}" 2>&1 &
proxy_pid=$!

# Shutdown: stop both processes and scrub the key from disk.
cat > "${PW_PARENT_JOB_DIR}/cancel.sh" <<EOF
kill ${gw_pid} ${proxy_pid} 2>/dev/null
rm -f "${HERMES_HOME}/config.yaml"
EOF

echo "::notice::hermes-agent started | gateway pid ${gw_pid} (api 127.0.0.1:${hermes_api_port}) | proxy pid ${proxy_pid} (tunnel 0.0.0.0:${service_port}) | model=${service_model}"

# Keep the job (and the session tunnel) alive.
sleep inf
