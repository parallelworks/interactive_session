# LibreChat Container

A containerized deployment of [LibreChat](https://github.com/danny-avila/LibreChat), an open-source AI chat interface, running via Singularity on HPC clusters and cloud resources. Provides browser-based access to a multi-model AI assistant with persistent chat history, document upload, and RAG (retrieval-augmented generation) support.

## Features

- **Multi-model AI Chat**: Connect to OpenAI, Anthropic, Azure, or any OpenAI-compatible API
- **Container Runtime**: Singularity/Apptainer — no root or Docker required
- **FIPS Compatible**: Runs on FIPS-enabled HPC systems (e.g., HSP/DoD clusters)
- **Persistent Storage**: Chat history, uploaded files, and images are stored in your home directory
- **RAG Support**: Upload documents and query them with vector search (pgvector + MeiliSearch)
- **Scheduler Support**: Works with both SLURM and PBS job schedulers

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

### Container Runtime
Singularity is the only supported runtime. On systems where `singularity` is not in the default `PATH`, the session will attempt to load it via `module load apptainer` or `module load singularity` automatically.

### Compute Resources
LibreChat itself is lightweight, but the RAG pipeline (PostgreSQL + pgvector) benefits from additional memory for large document sets. A single CPU and 8–16 GB of memory is sufficient for most interactive use.

### Scheduler Settings (HSP)
On HSP clusters, configure your SLURM account, QoS, and node count as required by your allocation. The session defaults to a 30-minute walltime; increase this for longer working sessions.

## Requirements

- **Singularity/Apptainer**: Must be available on the target node (loaded automatically via `module` if needed).
- **SIF images**: Pre-pulled to `$service_parent_install_dir/containers/librechat/` by the controller script. The controller runs on the login node and handles the initial download.
- **AI API key**: At least one AI provider API key must be configured in LibreChat after first launch.

## Getting Started

1. Select your resource and scheduler settings
2. Optionally expand **LibreChat Settings** to change the clone directory (defaults to `~/pw/LibreChat`)
3. Launch the session — the controller will download the container images on first run (this may take a few minutes)
4. Once the session is ready, click the link to open LibreChat in your browser
5. On first launch, register a local account and configure your AI provider API keys under **Settings → API Keys**

The session will run until cancelled or the walltime expires. Chat history, uploads, and database files are stored under `<librechat_dir>/singularity-data/` and persist across sessions and job restarts as long as the directory is not deleted. Multiple users on the same cluster can share a single deployment by pointing to the same `librechat_dir`.
