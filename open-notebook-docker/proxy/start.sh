#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export VITE_BASE_PATH="${VITE_BASE_PATH:-/me/session/Matthew.Shaxted/notebook}"
export APP_PORT="${APP_PORT:-35231}"
export PROXY_PORT="${PROXY_PORT:-35200}"

echo "==> Base path:   $VITE_BASE_PATH"
echo "==> App port:    $APP_PORT"
echo "==> Proxy port:  $PROXY_PORT"

exec node "${SCRIPT_DIR}/proxy.mjs"
