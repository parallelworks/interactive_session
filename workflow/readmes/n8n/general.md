# n8n Interactive Session

[n8n](https://n8n.io) is a workflow automation platform that lets you connect applications, APIs, and services through a visual node editor — without writing code.

## Container Runtime

You can run n8n using **Docker** or **Singularity** — select the runtime in the form before launching. Use Singularity on clusters where Docker is not available or not permitted.

## Accessing the Session

Once the session starts, click the session URL in the Activate platform. Your browser will open the n8n editor at the session base path. The first time you visit, n8n will prompt you to enter your **name, email, and password** to create an owner account.

## n8n Data Directory

Workflows, credentials, and settings are stored in the **n8n Data Directory** you configure in the form (default: `~/pw/n8n`). If this path is on a shared or persistent filesystem, your data will survive across sessions. To reuse data from a previous session, set the same directory when launching a new one.

## Importing and Exporting Workflows

- **Export**: In the n8n editor, open a workflow → menu (⋮) → **Download**. This saves a `.json` file.
- **Import**: In the n8n editor, click **Add workflow** → **Import from file** and select the `.json` file.

Example workflows are available in the `n8n-workflow/examples/` directory of this repository.

## Image Version

The default n8n image tag is `1.123.4`. You can change it in the **n8n Image Tag** field before launching. Use `latest` to always pull the most recent release (not recommended for production — version pinning avoids unexpected breaking changes).

## Stopping the Session

Cancel the session from the Activate platform. The running container and its associated resources will be cleaned up automatically via the `cancel.sh` script.
