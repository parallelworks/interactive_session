#!/bin/bash

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_DIR="$BASE/singularity-data/pids"

for svc in librechat ragapi pgvector meilisearch mongodb; do
  pidfile="$PID_DIR/$svc.pid"
  if [ -f "$pidfile" ]; then
    pid=$(cat "$pidfile")
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" && echo "Stopped $svc (PID $pid)"
    else
      echo "$svc (PID $pid) was not running"
    fi
    rm -f "$pidfile"
  else
    echo "$svc has no PID file"
  fi
done
