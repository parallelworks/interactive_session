################################################################################
# Interactive Session Starter - Hermes Agent (NousResearch Hermes)
#
# Two interfaces, chosen by ${service_interface}:
#   dashboard -> run `hermes dashboard` (Hermes' native web UI, including a Chat
#                tab) bound to loopback on the endpoint-assigned port. The
#                endpoint forwards to loopback, so v3's tcp_proxy relay is not
#                needed: the dashboard's off-loopback auth gate never engages,
#                and the subdomain endpoint serves the SPA at the root URL.
#   chat      -> run Hermes' OpenAI api_server via `hermes gateway` on a PRIVATE
#                port, fronted by the key-injecting auth_proxy on the
#                endpoint-assigned port; `pw endpoints run --openai` registers
#                it as a model in the platform chat and AI providers. The proxy
#                stays because it also answers liveness probes, injects SSE
#                keepalive chunks (the platform chat parser aborts on silent
#                streams), and advertises the fleet marker at /_agent.
# Runs on: cluster login node (scheduler:false)
# Called by: Workflow after controller setup, with inputs.sh sourced
#
# Variables from inputs.sh:
#   service_name        service dir under the job dir (hermes-agent)
#   service_interface   dashboard | chat
#   service_model       brain model id (e.g. org:glm/glm-5.1)
#   service_allocation  X-Allocation for org:* models
#   pw_endpoints_args   Arguments for pw endpoints run (--name, ...)
# Brain credential = runtime PW_API_KEY (written only to the per-session Hermes
# config in the data dir, never to inputs.sh; scrubbed by cancel.sh).
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
# execution. (The endpoint/provider access is the boundary; see the README.)
export HERMES_YOLO_MODE=1

# Scrub the brain key at teardown (run by the cleanup trap)
echo "rm -f ${HERMES_HOME}/config.yaml" > cancel.sh

if [ "${service_interface}" = "dashboard" ]; then
    # Hermes' native web UI. The dashboard refuses to bind off-loopback without
    # an auth provider (v0.17 hardening), but the endpoint forwards to loopback,
    # so the loopback bind (where the auth gate does NOT engage) is exactly what
    # we need -- no relay, no prefix handling. The controller pre-builds the SPA;
    # --skip-build skips rebuild.
    # --rewrite-host: the endpoint proxy preserves the public Host header
    # (<name>.activate.pw), which the dashboard's host guard 400s; rewriting it
    # to localhost satisfies the guard (the same hardening that forces the
    # loopback bind).
    echo "::notice::Starting hermes dashboard behind pw endpoint"
    # {port} is replaced by pw endpoints run with the local port it forwards to
    pw endpoints run ${pw_endpoints_args} --rewrite-host=localhost -- hermes dashboard \
        --port {port} \
        --host 127.0.0.1 \
        --no-open \
        --skip-build

    if [ $? -ne 0 ]; then
        echo "::error title=Error::pw endpoints command failed"
        # Fail loud: without this, wait_for_endpoint polls forever for an
        # endpoint that will never register
        pw workflows runs cancel ${PW_RUN_SLUG}
        exit 1
    fi
else
    # OpenAI api_server (private loopback port) + key-injecting proxy on the
    # endpoint-assigned port (the api_server requires a bearer the platform
    # can't send). The gateway is started and health-gated BEFORE the endpoint
    # registers, so wait_for_endpoint can't complete the run against a gateway
    # that never came up.
    hermes_api_port=$("${PYBIN}" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
    api_key="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
    export API_SERVER_ENABLED=true
    export API_SERVER_HOST=127.0.0.1
    export API_SERVER_PORT="${hermes_api_port}"
    export API_SERVER_KEY="${api_key}"
    gw_log="${PW_PARENT_JOB_DIR}/hermes-gateway.out"
    hermes gateway > "${gw_log}" 2>&1 &
    gw_pid=$!
    # The api_server takes tens of seconds to bind; fail loud if it dies.
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
    echo "kill ${gw_pid} 2>/dev/null" >> cancel.sh

    echo "::notice::Starting auth proxy behind pw endpoint (--openai) | gateway pid ${gw_pid} (api 127.0.0.1:${hermes_api_port})"
    # {port} is replaced by pw endpoints run with the local port it forwards to
    pw endpoints run ${pw_endpoints_args} --openai -- "${PYBIN}" "${AGENT_DIR}/auth_proxy.py" \
        --listen "127.0.0.1:{port}" \
        --upstream "127.0.0.1:${hermes_api_port}" \
        --bearer "${api_key}" \
        --marker "${service_marker:-worker}"

    if [ $? -ne 0 ]; then
        echo "::error title=Error::pw endpoints command failed"
        # Fail loud: without this, wait_for_endpoint polls forever for an
        # endpoint that will never register
        pw workflows runs cancel ${PW_RUN_SLUG}
        exit 1
    fi
fi
