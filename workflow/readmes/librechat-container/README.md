# LibreChat Container

A containerized deployment of [LibreChat](https://github.com/danny-avila/LibreChat), an open-source AI chat interface, running via Singularity on HPC clusters and cloud resources. Provides browser-based access to a multi-model AI assistant with persistent chat history, document upload, and RAG (retrieval-augmented generation) support.

## Features

- **Multi-model AI Chat**: Connect to OpenAI, Anthropic, Azure, or any OpenAI-compatible API
- **Container Runtime**: Singularity/Apptainer — no root or Docker required
- **FIPS Compatible**: Runs on FIPS-enabled HPC systems (e.g., HSP/DoD clusters)
- **Persistent Storage**: Chat history, uploaded files, and database files are stored in your home directory
- **RAG Support**: Upload documents and query them with vector search (pgvector + MeiliSearch)
- **Scheduler Support**: Works with both SLURM and PBS job schedulers
- **Pre-configured Endpoints**: GenAI MIL and ACTIVATE platform endpoints set up automatically

## Architecture

The session runs five containerized services, all started from pre-built SIF images:

| Service | Purpose |
|---|---|
| **MongoDB** | Chat history and user data |
| **MeiliSearch** | Full-text search index |
| **PostgreSQL + pgvector** | Vector embeddings for RAG |
| **RAG API** | Document ingestion and retrieval |
| **LibreChat** | Web application (the browser UI) |

All service ports are dynamically allocated at runtime to avoid conflicts on shared nodes.

## Configuration

### LibreChat Settings

Expand the **LibreChat Settings** section in the launch form to customize the following:

| Field | Default | Description |
|---|---|---|
| **LibreChat directory** | `~/pw/LibreChat` | Path where the LibreChat repository is cloned. Shared across sessions — changing this will create an isolated deployment with a separate chat history. |
| **LibreChat config file** | `<librechat_dir>/librechat.yaml` | Path to a custom LibreChat YAML configuration file. If left blank, the auto-generated config (with GenAI MIL and ACTIVATE endpoints) is used. |
| **LibreChat Database Directory** | `<librechat_dir>/singularity-data/mongodb` | Path where MongoDB stores its data files. Change this to share a database between different deployments or to point to a pre-existing database. |

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

### Container Runtime

Singularity is the only supported runtime. On systems where `singularity` is not in the default `PATH`, the session will attempt to load it via `module load apptainer` or `module load singularity` automatically.

### Compute Resources

LibreChat itself is lightweight, but the RAG pipeline (PostgreSQL + pgvector) benefits from additional memory for large document sets. A single CPU and 8–16 GB of memory is sufficient for most interactive use.

### Scheduler Settings (HSP)

On HSP clusters, configure your SLURM account, QoS, and node count as required by your allocation. The session defaults to a 30-minute walltime; increase this for longer working sessions.

## What Happens at Launch

1. **Controller (login node)**: Downloads the pre-built SIF images from the GitHub container registry on first run. Clones (or updates) the LibreChat repository to `librechat_dir`. Copies `.env.example` to `.env`, sets `DOMAIN_CLIENT` for Activate platform access, and appends any provided API keys. Writes a `librechat.yaml` pre-configured with the GenAI MIL and ACTIVATE platform endpoints (skipped if a custom `librechat_config` path is provided and points to an existing file).

2. **Start script (compute/login node)**: Allocates ports for all five services, then starts them in dependency order: MongoDB → MeiliSearch → PostgreSQL → RAG API → LibreChat. Each service is health-checked before the next one starts.

## Requirements

- **Singularity/Apptainer**: Must be available on the target node (loaded automatically via `module` if needed).
- **SIF images**: Downloaded to `$service_parent_install_dir/containers/librechat/` by the controller on first run. Subsequent launches skip the download if the images are already present.
- **AI API key**: At least one AI provider API key must be configured to start chatting. The ACTIVATE platform endpoint is available by default using your platform API key.

## Getting Started

1. Select your resource and scheduler settings
2. Optionally expand **LibreChat Settings** to customize paths (defaults work for most users)
3. Optionally expand **Environment Variables** to provide API keys (e.g., `GENAI_MIL_API_KEY`)
4. Launch the session — the controller will download the container images on first run (this may take a few minutes)
5. Once the session is ready, click the link to open LibreChat in your browser
6. On first launch, register a local account; the GenAI MIL and ACTIVATE endpoints will already be configured

## Persistence

All data is stored under `<librechat_dir>/singularity-data/` by default:

| Path | Contents |
|---|---|
| `singularity-data/mongodb/` | Chat history, users, conversations (overridden by **LibreChat Database Directory**) |
| `singularity-data/meili/` | MeiliSearch index |
| `singularity-data/pgdata/` | PostgreSQL data (RAG embeddings) |
| `singularity-data/pids/` | Process ID files for graceful shutdown |
| `singularity-data/logs/` | Per-service log files |

Data persists across sessions and job restarts as long as the directory is not deleted. Multiple users on the same cluster can share a single deployment by pointing to the same `librechat_dir`.
