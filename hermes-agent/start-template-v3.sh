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

# Private venv python for the small resolve_model helper (see tools/utils/agent_env.sh).
# Hermes itself runs from its own installer-provided Python.
. "${PW_PARENT_JOB_DIR}/tools/utils/agent_env.sh"
PYBIN="$(agent_python_bin)"

# Persistent Hermes home: conversation history (sessions/, state.db), skills/,
# memories/, kanban.db, cron/ and SOUL.md live here and SURVIVE cancel/rerun --
# it is NOT the per-run job dir. Default ~/.hermes-agent; the form can repoint it.
# The brain key is (re)written into it each launch and scrubbed on cancel.
data_dir="${service_data_dir:-~/.hermes-agent}"
export HERMES_HOME="${data_dir/#\~/$HOME}"          # expand a leading ~
[ "${service_fresh_start}" = "true" ] && rm -rf "${HERMES_HOME}"
mkdir -p "${HERMES_HOME}"
# Drop stale single-instance locks left by a hard-cancelled previous run.
rm -f "${HERMES_HOME}/gateway.lock" "${HERMES_HOME}/auth.lock" 2>/dev/null || true

# Install the persona (form value) as SOUL.md. Hermes reads it per-message and
# never rewrites it, so the form is its source of truth -- (re)write each launch.
if [ -s "${PW_PARENT_JOB_DIR}/soul.md" ]; then
    cp "${PW_PARENT_JOB_DIR}/soul.md" "${HERMES_HOME}/SOUL.md"
fi

# Brain -> ACTIVATE platform OpenAI-compatible endpoint (used by BOTH interfaces).
# Hermes' "custom" provider reads the bearer from model.api_key (NOT OPENAI_API_KEY),
# and org:* models need the X-Allocation header, sent via default_headers.
brain_base_url="https://${PW_PLATFORM_HOST}/api/openai/v1"
# The Chat model picker shows a short name (e.g. /gpt-oss-20b for a session-served
# model); the endpoint routes by the full provider id. Resolve it before handing it
# to Hermes (warnings, incl. "not an exact id", go to this start log).
resolved_model="$(OPENAI_BASE_URL="${brain_base_url}" OPENAI_API_KEY="${PW_API_KEY}" \
    X_ALLOCATION="${service_allocation}" \
    "${PYBIN}" "${PW_PARENT_JOB_DIR}/tools/utils/resolve_model.py" "${service_model:-org:glm/glm-5.1}")"
cat > "${HERMES_HOME}/config.yaml" <<EOF
model:
  default: "${resolved_model:-org:glm/glm-5.1}"
  provider: "custom"
  base_url: "${brain_base_url}"
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
    # Hermes' native web UI. As of the June 2026 hardening (Hermes >= v0.17.0)
    # the dashboard REFUSES to bind off-loopback unless an auth provider is
    # configured -- `--insecure` is now a documented no-op, not an
    # unauthenticated public bind. The session tunnel is already the access
    # boundary, so rather than bolt a password gate in front of it we bind the
    # dashboard to loopback (where the auth gate does NOT engage) and put a
    # byte-transparent TCP relay (tcp_proxy.py) on the tunnel-facing
    # ${service_port}. The relay forwards HTTP/SSE/WebSocket and the
    # X-Forwarded-Prefix header verbatim, so the SPA still works under the
    # session base path -- exactly as the direct 0.0.0.0 bind did before the
    # hardening. The controller pre-builds the SPA; --skip-build skips rebuild.
    dash_port=$(( ${service_port} + 1 ))
    log="${PW_PARENT_JOB_DIR}/hermes-dashboard.out"
    proxy_log="${PW_PARENT_JOB_DIR}/dashboard-proxy.out"
    hermes dashboard --port "${dash_port}" --host 127.0.0.1 --no-open --skip-build > "${log}" 2>&1 &
    pid=$!
    # Expose the relay only once the loopback dashboard accepts connections, so
    # the session readiness probe never races a not-yet-listening backend; fail
    # loud if it never comes up (e.g. a future auth change) instead of leaving
    # create_session to spin until timeout.
    ready=""
    for _ in $(seq 1 60); do
        if curl -fsS -m 2 -o /dev/null "http://127.0.0.1:${dash_port}/"; then ready=1; break; fi
        kill -0 "${pid}" 2>/dev/null || break
        sleep 1
    done
    if [ -z "${ready}" ]; then
        echo "::error title=Dashboard failed to start::loopback dashboard never came up; see ${log}"
        tail -n 40 "${log}" 2>/dev/null || true
        exit 1
    fi
    "${PYBIN}" "${AGENT_DIR}/tcp_proxy.py" --listen "0.0.0.0:${service_port}" --upstream "127.0.0.1:${dash_port}" > "${proxy_log}" 2>&1 &
    proxy_pid=$!
    echo "kill ${pid} ${proxy_pid} 2>/dev/null; pkill -P ${pid} 2>/dev/null; rm -f ${HERMES_HOME}/config.yaml" >> "${PW_PARENT_JOB_DIR}/cancel.sh"
    echo "::notice::hermes dashboard started (pid ${pid}, loopback :${dash_port}) | relay pid ${proxy_pid} on 0.0.0.0:${service_port} | log: ${log}"
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
    # The api_server takes tens of seconds to bind. Wait for it before exposing
    # the relay, otherwise create_session sees the relay's liveness 200 and marks
    # the session "ready" while chat requests still 502 against the not-yet-up
    # gateway. Fail loud if the gateway dies instead of serving a broken session.
    ready=""
    for _ in $(seq 1 120); do
        if curl -fsS -m 2 -o /dev/null "http://127.0.0.1:${hermes_api_port}/health"; then ready=1; break; fi
        kill -0 "${gw_pid}" 2>/dev/null || break
        sleep 1
    done
    if [ -z "${ready}" ]; then
        echo "::error title=Gateway failed to start::api_server never came up; see ${gw_log}"
        tail -n 40 "${gw_log}" 2>/dev/null || true
        exit 1
    fi
    "${PYBIN}" "${AGENT_DIR}/auth_proxy.py" \
        --listen "0.0.0.0:${service_port}" \
        --upstream "127.0.0.1:${hermes_api_port}" \
        --bearer "${api_key}" \
        --marker "${service_marker:-worker}" > "${proxy_log}" 2>&1 &
    proxy_pid=$!
    echo "kill ${gw_pid} ${proxy_pid} 2>/dev/null; rm -f ${HERMES_HOME}/config.yaml" >> "${PW_PARENT_JOB_DIR}/cancel.sh"
    # Fail loud if the proxy didn't come up (e.g. it crashed on import): otherwise
    # the gateway is healthy but nothing listens on the tunnel port and the session
    # just hangs "pending" with no obvious cause.
    proxy_ready=""
    for _ in $(seq 1 15); do
        if curl -fsS -m 2 -o /dev/null "http://127.0.0.1:${service_port}/health"; then proxy_ready=1; break; fi
        kill -0 "${proxy_pid}" 2>/dev/null || break
        sleep 1
    done
    if [ -z "${proxy_ready}" ]; then
        echo "::error title=Auth proxy failed to start::nothing listening on ${service_port}; see ${proxy_log}"
        tail -n 40 "${proxy_log}" 2>/dev/null || true
        exit 1
    fi
    echo "::notice::hermes chat started | gateway pid ${gw_pid} (api 127.0.0.1:${hermes_api_port}) | proxy pid ${proxy_pid} (tunnel 0.0.0.0:${service_port})"
fi

# Keep the job (and the session tunnel) alive.
sleep inf
