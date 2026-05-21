# LibreChat Singularity Manager

A lightweight web UI for managing a running [librechat-singularity](../librechat-container/) session. Provides a browser-based dashboard to check service status, view logs, and restart individual containers without stopping the workflow job.

## Prerequisites

A **librechat-singularity** session must already be running on the same resource. The manager reads `service.env` written by that session to locate service ports and restart scripts.

## Features

- **Live status**: Each service (MongoDB, MeiliSearch, PostgreSQL/pgvector, RAG API, LibreChat) shows a green (running) or red (stopped) indicator, updated every 5 seconds
- **Restart individual services**: Click **↺ Restart** on any card to restart that service without affecting others
- **Restart all**: The **↺ Restart All** button restarts all five services in dependency order
- **Live console output**: Restart output streams to the console panel in real time
- **Service logs**: Click **Logs** to view the last 100 lines of any service's log in the console

## Launch

1. Start a **librechat-singularity** session first and wait for it to be ready
2. Launch this session on the **same resource** with the same **LibreChat directory** (`~/pw/LibreChat` by default)
3. Once the manager is ready, click the link to open the dashboard in your browser

## Configuration

| Field | Default | Description |
|---|---|---|
| **LibreChat directory** | `~/pw/LibreChat` | Must match the `librechat_dir` used by the librechat-singularity session you want to manage |

## Important Notes

- The manager must run on the **same node** as the LibreChat session. Both sessions should use `Schedule Job? = No` (login node) unless you have a way to target the same compute node.
- Restarting a service does **not** stop the workflow job or affect other services. Ports are preserved between restarts.
- If the librechat-singularity session is stopped, the manager will show all services as stopped. Restart scripts are still present on disk; the manager will attempt to run them but they will fail if the ports are no longer allocated.

## Architecture

The manager runs a minimal Python HTTP server (stdlib only, no external dependencies) that:
- Reads PID files from `<librechat_dir>/singularity-data/pids/` to determine service status
- Tails log files from `<librechat_dir>/singularity-data/logs/`
- Executes restart shims from `<librechat_dir>/singularity-data/restart-*.sh` in background threads and streams output to the browser
