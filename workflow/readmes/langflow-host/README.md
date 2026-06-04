# Langflow Interactive Session

[Langflow](https://github.com/langflow-ai/langflow) is a visual builder for AI workflows. It lets you compose LLM pipelines, RAG chains, and multi-agent applications by connecting components in a drag-and-drop canvas — no code required.

## Getting Started

1. Select a **Service host** cluster from the form.
2. Optionally enable **Schedule Job?** to run on a compute node instead of the login node.
3. Adjust **Install Directory** and **Langflow Data Directory** if needed.
4. Click **Launch**. The first run downloads Python 3.11 and installs Langflow (~500 MB); subsequent runs reuse the cached installation and start in seconds.
5. Click the session URL in the platform once it turns active. Your browser will open the Langflow canvas.

## Installation

Langflow is installed automatically by the controller script into a Python 3.11 virtual environment under the **Install Directory** (default: `~/pw/software`; the venv is created at `<Install Directory>/langflow/venv`). The installation is shared across sessions launched on the same cluster, so it only runs once.

## Data Persistence

Flows, credentials, and settings are stored in the **Langflow Data Directory** (default: `~/pw/.langflow`). If this path is on a shared or persistent filesystem, your work survives across sessions. To resume a previous session's state, launch with the same data directory.

## Stopping the Session

Cancel the session from the Activate platform. The Langflow process is stopped automatically via `cancel.sh`.
