# Open Notebook (Docker)

Launch [Open Notebook](https://github.com/lfnovo/open-notebook) as an interactive session — a Streamlit-based AI research workspace backed by SurrealDB, running in Docker containers on your chosen compute resource.

## Features

- Full Open Notebook web UI accessible directly from the platform session
- Persistent data across session restarts when using stable data directories
- Nginx reverse proxy with session basepath integration
- Supports both privileged and rootless Docker environments
- SLURM and PBS scheduler support for running on compute nodes

## Use Cases

- AI-assisted research and note-taking with integrated LLM support
- Building and organizing knowledge bases from documents, web pages, and notes
- Persistent research workflows that outlast individual sessions (by reusing the same data directories)

## Configuration

### Open Notebook Settings

| Field | Description |
|-------|-------------|
| **Open Notebook Image** | Docker image for Open Notebook. Defaults to `lfnovo/open_notebook:v1-latest`. Pin a specific tag to lock the version. |
| **Encryption Key** | Required. A secret string used to encrypt stored API keys and sensitive data. Use the same value every restart to retain access to your existing data. |
| **Notebook Data Directory** | Path where Open Notebook stores its data files. Set to a persistent path (e.g. `${HOME}/open-notebook/data`) and reuse across sessions to preserve your work. |
| **SurrealDB Image** | Docker image for the SurrealDB backend. Defaults to `surrealdb/surrealdb:v2`. Change only to pin a specific version. |
| **Surreal Data Directory** | Path where SurrealDB stores its database files. Must be persistent and different from the Notebook Data Directory. |

### Compute Cluster Settings

| Field | Description |
|-------|-------------|
| **Service host** | The compute resource where the session runs. Docker must be available on this host. |
| **Schedule Job?** | Set to Yes to submit the session to the SLURM or PBS scheduler. Set to No (default) to run on the controller/login node. |
| **Walltime** | Maximum runtime when using a scheduler (default: 1 hour). |

## Requirements

- Docker must be installed and accessible on the target node (privileged or rootless)
- The `pw` agent binary must be in `PATH` (provided automatically by the platform)
- Outbound internet access from the service node is required on first launch to pull Docker images

## Getting Started

1. Select a compute resource with Docker available
2. Enter an **Encryption Key** — any secret string; remember it for future sessions
3. Set the **Notebook Data Directory** and **Surreal Data Directory** to persistent paths to preserve your data across sessions
4. Click **Execute** to launch
5. Wait for the session URL to appear, then click it to open Open Notebook in your browser
6. Configure your LLM provider API keys inside the Open Notebook settings panel
