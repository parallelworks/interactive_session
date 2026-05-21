# Langflow Interactive Session (Singularity)

[Langflow](https://github.com/langflow-ai/langflow) is a visual builder for AI workflows. It lets you compose LLM pipelines, RAG chains, and multi-agent applications by connecting components in a drag-and-drop canvas — no code required.

This version runs Langflow inside a **Singularity/Apptainer container**, making it suitable for HPC clusters that do not allow Docker but do provide Singularity or Apptainer.

## Getting Started

1. Select a **Service host** cluster from the form.
2. Optionally enable **Schedule Job?** to run on a compute node instead of the login node.
3. Adjust **Install Directory**, **Langflow Data Directory**, and the optional advanced settings if needed.
4. Click **Launch**. The first run downloads the Singularity container (~2–4 GB); subsequent runs reuse the cached container and start in seconds.
5. Click the session URL in the platform once it turns active. Your browser will open the Langflow canvas.

## Container

The Langflow container is built from the official Docker image (`langflowai/langflow`) and stored as a Singularity sandbox. It is downloaded once to the **Install Directory** and shared across all sessions launched on the same cluster.

To rebuild or update the container, use `langflow-singularity/build-container.sh` from a machine with Singularity and ORAS installed.

## Data Persistence

Flows, credentials, and settings are stored in the **Langflow Data Directory** (default: `~/pw/.langflow`). If this path is on a shared or persistent filesystem, your work survives across sessions. To resume a previous session's state, launch with the same data directory.

The **Database URL** (default: `sqlite:////~/pw/.langflow/langflow.db`) controls where Langflow stores its internal database. The default SQLite file lives in the data directory so it is preserved across sessions automatically. To use a PostgreSQL backend, set a `postgresql://` URL here.

## Custom Components

There are two ways to add custom components, and they serve different purposes:

- **Config Directory** (`<Config Directory>/components/`, default `~/pw/.langflow/components/`) — for personal components stored alongside your flows and data. Drop `.py` files here and Langflow discovers them automatically at startup. No extra configuration needed beyond the config dir you already have.
- **Custom Components Path** — for components that live *outside* your Langflow data directory: a git-managed repo, a shared team folder on the cluster filesystem, etc. The directory is bind-mounted into the container. Use this when you want to version-control components separately or share them across users; for personal components, the Config Directory approach is simpler.

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
| `LANGFLOW_CONFIG_DIR` | form input | Config/custom-components directory (default: `~/pw/.langflow`) |
| `LANGFLOW_COMPONENTS_PATH` | form input | Extra custom components directory; only set when provided |
| `LANGFLOW_DATABASE_URL` | form input | Database URL (default: `sqlite:////~/pw/.langflow/langflow.db`) |

## Stopping the Session

Cancel the session from the Activate platform. The Langflow process is stopped automatically via `cancel.sh`.
