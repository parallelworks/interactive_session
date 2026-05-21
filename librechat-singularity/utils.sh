#!/bin/bash
# Common helper functions for LibreChat service scripts.
# Sourced by start-template-v3.sh; also sourced automatically by each start-*.sh
# when they are run standalone (after sourcing service.env).

stop_existing() {
  local name="$1"
  local pidfile="$PID_DIR/$name.pid"
  if [ -f "$pidfile" ]; then
    local pid
    pid=$(cat "$pidfile")
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" && echo "::notice::Stopped existing $name (PID $pid)"
      sleep 1
    fi
    rm -f "$pidfile"
  fi
}

run_bg() {
  local name="$1"; shift
  nohup "$@" > "$LOG_DIR/$name.log" 2>&1 &
  echo $! > "$PID_DIR/$name.pid"
  echo "::notice::Started $name (PID $!)"
}

wait_for_port() {
  local port="$1" label="$2"
  echo "::notice::Waiting for $label on port $port..."
  local attempts=0
  until bash -c ">/dev/tcp/localhost/$port" 2>/dev/null; do
    sleep 1
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 60 ]; then
      echo "::error::$label did not start within 60s. Check $LOG_DIR/${label,,}.log"
      exit 1
    fi
  done
  echo "::notice::$label is ready"
}
