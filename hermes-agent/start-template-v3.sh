################################################################################
# Interactive Session Starter - Hermes Agent (NousResearch Hermes)
#
# Two interfaces, chosen by ${service_interface}:
#   dashboard -> run `hermes dashboard` (Hermes' native web UI, including a Chat
#                tab) on ${service_port}; the session opens it in the browser.
#                The SPA honours the session URL prefix via X-Forwarded-Prefix.
#   chat      -> run Hermes' OpenAI api_server via `hermes gateway` on a PRIVATE
#                port, fronted by a key-injecting proxy on ${service_port}; the
#                session is openAI:true and registers as a chat provider.
# Runs on: cluster login node (scheduler:false)
# Called by: session_runner, after inputs.sh is sourced and ${service_port} is set
#
# Variables from inputs.sh:
#   service_name        service dir under the job dir (hermes-agent)
#   service_interface   dashboard | chat
#   service_model       brain model id (e.g. org:glm/glm-5.1)
#   service_allocation  X-Allocation for org:* models
#   service_port        tunnel-facing port (set by session_runner)
# Brain credential = runtime PW_API_KEY (written only to the per-session Hermes
# config in the job dir, never to inputs.sh; scrubbed by cancel.sh).
################################################################################
set -x

AGENT_DIR="${PW_PARENT_JOB_DIR}/${service_name:-hermes-agent}"
export PATH="${HOME}/.local/bin:${HOME}/pw:${PATH}"   # hermes + pw on PATH

# Per-session Hermes home: config (incl. the brain key) and data live in the job
# dir, isolated per run — not in ${HOME}/.hermes.
export HERMES_HOME="${PW_PARENT_JOB_DIR}/hermes-home"
mkdir -p "${HERMES_HOME}"

# Brain -> ACTIVATE platform OpenAI-compatible endpoint (used by BOTH interfaces).
# Hermes' "custom" provider reads the bearer from model.api_key (NOT OPENAI_API_KEY),
# and org:* models need the X-Allocation header, sent via default_headers.
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

# Unattended service: no human approval channel, so auto-approve tool/command
# execution. (The session/provider access is the boundary; see the README.)
export HERMES_YOLO_MODE=1

: > "${PW_PARENT_JOB_DIR}/cancel.sh"

if [ "${service_interface}" = "dashboard" ]; then
    # Hermes' native web UI on ${service_port}. --insecure is required to bind
    # off-loopback (the session tunnel is the access boundary). The SPA is
    # pre-built by the controller; --skip-build avoids rebuilding on launch.
    log="${PW_PARENT_JOB_DIR}/hermes-dashboard.out"
    hermes dashboard --port "${service_port}" --host 0.0.0.0 --insecure --no-open --skip-build > "${log}" 2>&1 &
    pid=$!
    echo "kill ${pid} 2>/dev/null; pkill -P ${pid} 2>/dev/null; rm -f ${HERMES_HOME}/config.yaml" >> "${PW_PARENT_JOB_DIR}/cancel.sh"
    echo "::notice::hermes dashboard started (pid ${pid}) on 0.0.0.0:${service_port} | log: ${log}"
else
    # OpenAI api_server (private loopback port) + key-injecting proxy on the
    # tunnel-facing port (the api_server requires a bearer the tunnel can't send).
    hermes_api_port=$(( ${service_port} + 1 ))
    api_key="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
    export API_SERVER_ENABLED=true
    export API_SERVER_HOST=127.0.0.1
    export API_SERVER_PORT="${hermes_api_port}"
    export API_SERVER_KEY="${api_key}"
    gw_log="${PW_PARENT_JOB_DIR}/hermes-gateway.out"
    proxy_log="${PW_PARENT_JOB_DIR}/auth-proxy.out"
    hermes gateway > "${gw_log}" 2>&1 &
    gw_pid=$!
    python3 "${AGENT_DIR}/auth_proxy.py" \
        --listen "0.0.0.0:${service_port}" \
        --upstream "127.0.0.1:${hermes_api_port}" \
        --bearer "${api_key}" > "${proxy_log}" 2>&1 &
    proxy_pid=$!
    echo "kill ${gw_pid} ${proxy_pid} 2>/dev/null; rm -f ${HERMES_HOME}/config.yaml" >> "${PW_PARENT_JOB_DIR}/cancel.sh"
    echo "::notice::hermes chat started | gateway pid ${gw_pid} (api 127.0.0.1:${hermes_api_port}) | proxy pid ${proxy_pid} (tunnel 0.0.0.0:${service_port})"
fi

# Keep the job (and the session tunnel) alive.
sleep inf
