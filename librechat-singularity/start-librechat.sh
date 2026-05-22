#!/bin/bash
# Starts (or restarts) LibreChat. Calls stop_existing before launching, so
# running this script a second time is a clean restart.
# Sourced by start-template-v3.sh; run directly to restart during a session.

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

# dotenv does not override existing env vars, so empty vars passed in by the
# workflow (e.g. JWT_SECRET='') would shadow the .env file values.
for _var in GENAI_MIL_API_KEY JWT_SECRET JWT_REFRESH_SECRET LIBRECHAT_API_KEY LANGFLOW_API_KEY; do
    [ -z "${!_var}" ] && unset "$_var"
done
unset _var

echo "::notice::Starting LibreChat..."
_librechat_yaml="${librechat_config:-$BASE/librechat.yaml}"
librechat_config_bind=()
[ -f "$_librechat_yaml" ] && librechat_config_bind=(--bind "$_librechat_yaml:/app/librechat.yaml")

# ── Patch index.html for reverse-proxy subpath deployment ────────────────────
# When LibreChat sits behind a proxy that strips a basepath (e.g. /me/session/…),
# assets and API calls must include that prefix. We extract index.html from the
# container, fix <base href>, and inject a fetch/XHR intercept that prepends the
# basepath to all /api/ requests so the proxy can route them correctly.
librechat_html_bind=()
if [ -n "${basepath:-}" ]; then
    _patched="$BASE/custom-index.html"
    singularity exec "$SIF/librechat.sif" cat /app/client/dist/index.html > "$_patched"
    python3 - "$_patched" "${basepath}" <<'PYEOF'
import sys, re
path, bp = sys.argv[1], sys.argv[2]
with open(path) as f:
    html = f.read()
html = html.replace('<base href="/" />', f'<base href="{bp}/" />')
patch = (
    f'<script>(function(){{'
    f'var bp="{bp}",org=window.location.origin;'
    f'function p(u){{if(typeof u!=="string")return u;'
    f'if(u.startsWith("/api/"))return bp+u;'
    f'if(u.startsWith(org+"/api/"))return org+bp+u.slice(org.length);'
    f'return u;}}'
    f'var oF=window.fetch;window.fetch=function(u,o){{return oF.call(this,p(u),o)}};'
    f'var oO=XMLHttpRequest.prototype.open;'
    f'XMLHttpRequest.prototype.open=function(m,u){{[].splice.call(arguments,1,1,p(u));return oO.apply(this,arguments)}};'
    f'}})();</script>'
)
html = re.sub(r'(</head>)', patch + r'\1', html, count=1)
with open(path, 'w') as f:
    f.write(html)
print(f"::notice::Patched index.html for basepath {bp}")
PYEOF
    librechat_html_bind=(--bind "$_patched:/app/client/dist/index.html")
fi

stop_existing librechat
run_bg librechat \
  singularity exec \
    --writable-tmpfs \
    --pwd /app \
    --bind "$BASE/.env:/app/.env" \
    "${librechat_config_bind[@]}" \
    "${librechat_html_bind[@]}" \
    --bind "$BASE/images:/app/client/public/images" \
    --bind "$BASE/uploads:/app/uploads" \
    --bind "$BASE/logs:/app/logs" \
    --env HOST=0.0.0.0 \
    --env "PORT=$service_port" \
    --env "DOMAIN_SERVER=http://localhost:$service_port" \
    --env "MONGO_URI=mongodb://localhost:$MONGODB_PORT/LibreChat" \
    --env "MEILI_HOST=http://localhost:$MEILI_PORT" \
    --env "RAG_API_URL=http://localhost:$RAG_PORT" \
    "$SIF/librechat.sif" \
    npm run backend

wait_for_port "$service_port" "LibreChat"
