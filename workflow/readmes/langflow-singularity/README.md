# Langflow Interactive Session (Singularity)

[Langflow](https://github.com/langflow-ai/langflow) is a visual builder for AI workflows. It lets you compose LLM pipelines, RAG chains, and multi-agent applications by connecting components in a drag-and-drop canvas — no code required.

This version runs Langflow inside a **Singularity/Apptainer container**, making it suitable for HPC clusters that do not allow Docker but do provide Singularity or Apptainer.

## Getting Started

1. Select a **Service host** cluster from the form.
2. Optionally enable **Schedule Job?** to run on a compute node instead of the login node.
3. Adjust **Install Directory** and **Langflow Data Directory** if needed.
4. Click **Launch**. The first run downloads the Singularity container (~2–4 GB); subsequent runs reuse the cached container and start in seconds.
5. Click the session URL in the platform once it turns active. Your browser will open the Langflow canvas.

## Container

The Langflow container is built from the official Docker image (`langflowai/langflow`) and stored as a Singularity sandbox. It is downloaded once to the **Install Directory** and shared across all sessions launched on the same cluster.

To rebuild or update the container, use `langflow-singularity/build-container.sh` from a machine with Singularity and ORAS installed.

## Data Persistence

Flows, credentials, and settings are stored in the **Langflow Data Directory** (default: `~/pw/.langflow`). If this path is on a shared or persistent filesystem, your work survives across sessions. To resume a previous session's state, launch with the same data directory.

## Requirements

- Singularity ≥ 3.x or Apptainer ≥ 1.x must be available on the cluster (either in `PATH` or via `module load apptainer`/`module load singularity`).

## Environment

The session sets the following Langflow environment variables automatically:

| Variable | Value | Effect |
|---|---|---|
| `DO_NOT_TRACK` | `true` | Disables telemetry |
| `LANGFLOW_DO_NOT_TRACK` | `true` | Disables telemetry (fallback) |
| `LANGFLOW_ALEMBIC_LOG_TO_STDOUT` | `true` | Sends database migration logs to stdout |
| `LANGFLOW_SKIP_AUTH_AUTO_LOGIN` | `true` | Skips API key check when auto-login is enabled |

## Stopping the Session

Cancel the session from the Activate platform. The Langflow process is stopped automatically via `cancel.sh`.
