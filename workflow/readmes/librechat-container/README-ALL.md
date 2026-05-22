# LibreChat + Manager (All-in-One)

A containerized deployment of [LibreChat](https://github.com/danny-avila/LibreChat) bundled with a built-in management dashboard, both launched as a single workflow on HSP clusters. The LibreChat session runs the full AI chat application; the Manager session provides a browser-based UI to check service status, view logs, and restart individual services without stopping the workflow job.

## Features

- **Multi-model AI Chat**: Connect to OpenAI, Anthropic, Azure, or any OpenAI-compatible API
- **Built-in Manager UI**: Monitor and restart services from the browser — no terminal required
- **Container Runtime**: Singularity/Apptainer — no root or Docker required
- **FIPS Compatible**: Runs on FIPS-enabled HPC systems (e.g., HSP/DoD clusters)
- **Persistent Storage**: Chat history, uploaded files, and database files are stored in your home directory
- **RAG Support**: Upload documents and query them with vector search (pgvector + MeiliSearch)
- **Scheduler Support**: Works with both SLURM and PBS job schedulers
- **Pre-configured Endpoints**: GenAI MIL and ACTIVATE platform endpoints set up automatically

## Architecture

Two sessions are launched in parallel under a single workflow job:

### LibreChat Session
Runs five containerized services from pre-built SIF images:

| Service | Purpose |
|---|---|
| **MongoDB** | Chat history and user data |
| **MeiliSearch** | Full-text search index |
| **PostgreSQL + pgvector** | Vector embeddings for RAG |
| **RAG API** | Document ingestion and retrieval |
| **LibreChat** | Web application (the browser UI) |

### Manager Session
A lightweight Python HTTP server that reads `service.env` written by the LibreChat session and exposes a dashboard for:

- **Live status**: Green/red indicators for each service, polled every 5 seconds
- **Restart individual services**: Restart any service without affecting others or stopping the job
- **Restart all**: Restart all five services in dependency order
- **Live console output**: Restart output streams to the browser in real time
- **Service logs**: View the last 100 lines of any service log

All service ports are dynamically allocated at runtime to avoid conflicts on shared nodes.

## Sessions and Links

After launch, two session links appear in the workflow:

| Session | Description |
|---|---|
| **librechat** | Opens LibreChat directly (redirects to `/login`) |
| **manager** | Opens the service management dashboard |

The manager session waits for the LibreChat session to write `service.env` before starting, so both links become available at roughly the same time.

## Configuration

### LibreChat Settings

Expand the **LibreChat Settings** section in the launch form to customize the following:

| Field | Default | Description |
|---|---|---|
| **LibreChat directory** | `~/pw/LibreChat` | Path where the LibreChat repository is cloned. Shared across sessions — changing this creates an isolated deployment with a separate chat history. |
| **LibreChat config file** | `<librechat_dir>/librechat.yaml` | Path to a custom LibreChat YAML configuration file. If left blank, the auto-generated config (with GenAI MIL and ACTIVATE endpoints) is used. |
| **LibreChat Database Directory** | `<librechat_dir>/singularity-data/mongodb` | Path where MongoDB stores its data files. Change this to share a database between deployments or to point to a pre-existing database. |
| **Domain Client** | `ACTIVATE` | Set to `ACTIVATE` when accessing through the Activate platform (the default). Set to `LOCALHOST` only when accessing via an SSH tunnel or directly on localhost. |

### Environment Variables

Expand the **Environment Variables** section to provide API keys. All fields are optional — only configure the services you intend to use.

| Field | Description |
|---|---|
| **GENAI MIL API Key** | API key for the GenAI MIL endpoint (`api.genai.mil`). Enables the pre-configured GenAI MIL custom endpoint in LibreChat. |
| **JWT Secret** | Overrides the auto-generated JWT secret used to sign user session tokens. Set this to keep sessions valid across job restarts. |
| **JWT Refresh Secret** | Overrides the auto-generated JWT refresh secret. Set alongside JWT Secret for persistent sessions. |
| **LibreChat API Key** | API key for programmatic access to the LibreChat API. |
| **Langflow API Key** | API key for Langflow integration. |

The `PW_API_KEY` (your Activate platform API key) is injected automatically and used to configure the ACTIVATE platform endpoint.

### Compute Cluster Settings (HSP)

Configure SLURM or PBS scheduler settings as required by your allocation. Both the LibreChat and Manager sessions use the same cluster settings. The default walltime is 30 minutes; increase this for longer working sessions.

Both sessions run on the login node by default (`Schedule Job? = No`). This is the recommended setting because the Manager needs to reach the same node as LibreChat to read its PID files and restart scripts. If you submit to a compute node via the scheduler, both sessions must land on the same node.

### Container Runtime

Singularity is the only supported runtime. If `singularity` is not in the default `PATH`, the session will attempt to load it via `module load apptainer` or `module load singularity` automatically.

## What Happens at Launch

Both sessions start in parallel:

1. **LibreChat preprocessing (login node)**:
   - Downloads pre-built SIF images from the GitHub container registry on first run
   - Clones (or updates) the LibreChat repository to `librechat_dir`
   - Writes `.env` with `DOMAIN_CLIENT`, API keys, and auto-generated JWT secrets
   - Writes `librechat.yaml` pre-configured with GenAI MIL and ACTIVATE endpoints
   - Places a lock file at `<librechat_dir>/.librechat.lock` to prevent two sessions from sharing the same directory simultaneously

2. **LibreChat start (compute or login node)**:
   - Allocates ports for all five services
   - Starts services in dependency order: MongoDB → MeiliSearch → PostgreSQL → RAG API → LibreChat
   - Each service is health-checked before the next starts
   - Writes `service.env` with all port assignments and paths, which the Manager reads on startup

3. **Manager preprocessing (login node)**:
   - Checks out the manager scripts from the repository

4. **Manager start (compute or login node)**:
   - Waits up to 10 minutes for `service.env` to appear (retrying every 60 seconds)
   - Once `service.env` is available, starts the Flask dashboard on its allocated port

## Requirements

- **Singularity/Apptainer**: Must be available on the target node.
- **SIF images**: Downloaded to `$service_parent_install_dir/containers/librechat/` by the controller on first run. Subsequent launches skip the download if already present.
- **Same node**: LibreChat and Manager must run on the same node. With `Schedule Job? = No` (default), both run on the login node, which guarantees this.
- **AI API key**: At least one AI provider API key must be configured to start chatting. The ACTIVATE platform endpoint is available by default using your platform API key.

## Getting Started

1. Select your resource and scheduler settings
2. Optionally expand **LibreChat Settings** to customize paths (defaults work for most users)
3. Optionally expand **Environment Variables** to provide API keys (e.g., `GENAI_MIL_API_KEY`)
4. Launch the workflow — the controller downloads container images on first run (this may take a few minutes)
5. Once the sessions are ready, two links appear:
   - Click the **librechat** link to open LibreChat in your browser
   - Click the **manager** link to open the service management dashboard
6. On first launch, register a local account in LibreChat; the GenAI MIL and ACTIVATE endpoints will already be configured

## Using the Manager

The Manager dashboard shows a card for each of the five services. Each card displays:
- **Status indicator**: green (running) or red (stopped), refreshed every 5 seconds
- **↺ Restart button**: restarts that service independently, preserving its port
- **Logs button**: streams the last 100 lines of the service log to the console panel

The **↺ Restart All** button at the top restarts all services in dependency order (MongoDB first, LibreChat last).

Restart output streams to the console panel in real time. Restarting a service does **not** stop the workflow job or affect other running services.

## Restarting Services Without the Manager

You can also restart services directly from a terminal. Convenience shims are written to `<librechat_dir>/singularity-data/` at session start:

```bash
# Restart one service
bash ~/pw/LibreChat/singularity-data/restart-librechat.sh

# Restart all services in dependency order
bash ~/pw/LibreChat/singularity-data/restart-all.sh
```

Available shims: `restart-mongodb.sh`, `restart-meilisearch.sh`, `restart-pgvector.sh`, `restart-ragapi.sh`, `restart-librechat.sh`, `restart-all.sh`.

Or invoke the start scripts directly after sourcing `service.env`:

```bash
source ~/pw/LibreChat/singularity-data/service.env
bash $SCRIPTS_DIR/start-librechat.sh
```

Restarting a service does **not** affect the workflow job or any other running service. Logs are appended to the existing per-service log file in `singularity-data/logs/`.

## Persistence

All data is stored under `<librechat_dir>/singularity-data/` by default:

| Path | Contents |
|---|---|
| `singularity-data/mongodb/` | Chat history, users, conversations (overridden by **LibreChat Database Directory**) |
| `singularity-data/meili/` | MeiliSearch index |
| `singularity-data/pgdata/` | PostgreSQL data (RAG embeddings) |
| `singularity-data/pids/` | Process ID files for graceful shutdown |
| `singularity-data/logs/` | Per-service log files |
| `singularity-data/service.env` | Runtime state (ports, paths) — read by Manager and restart scripts |

Data persists across sessions and job restarts as long as the directory is not deleted. Multiple users on the same cluster can share a single deployment by pointing to the same `librechat_dir`.

## Comparison with Single-Session Workflow

| Feature | `hsp.yaml` (LibreChat only) | `hsp-all.yaml` (LibreChat + Manager) |
|---|---|---|
| LibreChat chat UI | ✓ | ✓ |
| Manager dashboard | Separate workflow | Built-in |
| Session links | 1 | 2 |
| Restart without terminal | ✗ | ✓ |
| Live service logs in browser | ✗ | ✓ |
| Resource overhead | Lower | Minimal extra (manager is a small Python process) |
