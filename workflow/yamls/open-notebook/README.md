# Open Notebook

Launch [Open Notebook](https://github.com/lfnovo/open-notebook) as an interactive session — a Streamlit-based AI research workspace backed by SurrealDB, running in Docker containers on your chosen compute resource.

## Features

- Full Open Notebook web UI accessible directly from the platform session
- Persistent SurrealDB database and notebook data across session restarts (when using a stable data directory)
- Nginx reverse proxy with session basepath integration
- Supports both privileged and rootless Docker environments
- SLURM and PBS scheduler support for running on compute nodes

## Use Cases

- AI-assisted research and note-taking with integrated LLM support
- Building and organizing knowledge bases from documents, web pages, and notes
- Persistent research workflows that outlast individual sessions (by reusing a data directory)

## Configuration

### Open Notebook Settings

| Field | Description |
|-------|-------------|
| **Encryption Key** | Required. A secret string used to encrypt stored API keys and sensitive data. Use the same value every time you restart to keep access to your stored data. |
| **Open Notebook Image Tag** | Docker image tag for `lfnovo/open_notebook`. Defaults to `v1-latest`. |
| **Data Directory** | Path on the service node where database and notebook files are stored. Set this to a stable path (e.g. `${HOME}/pw/open-notebook-data`) and reuse it across sessions to preserve your data. |

### Compute Cluster Settings

| Field | Description |
|-------|-------------|
| **Service host** | The compute resource where the session will run. Docker must be available on this host. |
| **Schedule Job?** | Set to Yes to submit the session to the SLURM or PBS scheduler. Set to No (default) to run on the controller/login node. |
| **Walltime** | Maximum runtime when using a scheduler (default: 4 hours). |

## Requirements

- Docker must be installed and accessible on the target node (privileged or rootless)
- The `pw` agent binary must be in `PATH` (provided automatically by the platform)
- Outbound internet access from the service node is required on first launch to pull Docker images

## Getting Started

1. Select a compute resource with Docker available
2. Enter an **Encryption Key** (any secret string — remember it for future sessions)
3. Set a **Data Directory** path where your data will be stored persistently
4. Click **Execute** to launch
5. Wait for the session URL to appear, then click it to open Open Notebook in your browser
6. Configure your LLM provider API keys inside the Open Notebook settings panel
