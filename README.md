# Interactive Sessions

This repository contains interactive session workflows for the Activate platform. Each workflow starts a web server on a compute cluster and connects it to the platform UI, giving users browser-based access to tools like JupyterLab, VS Code, VNC desktops, and web shells.

## Available Sessions

| Session | Description |
|---------|-------------|
| `jupyterlab-host` | JupyterLab notebook environment |
| `jupyter-host` | Legacy Jupyter Notebook |
| `openvscode` | VS Code in the browser |
| `vncserver` | Remote desktop (VNC) with various GUI applications |
| `webshell` | Browser-based terminal |

## How It Works

Each session is defined by **two bash scripts** and **one workflow YAML**:

1. **`controller-v3.sh`** -- Runs on the controller (login) node. Installs software and downloads dependencies. This node has internet access.
2. **`start-template-v3.sh`** -- Runs on the controller or compute node (depending on user selection). Starts the web service.
3. **Workflow YAML** (`workflow/yamls/<session>/<deployment>_v4.yaml`) -- Defines the platform UI form, generates the `inputs.sh` environment file, and calls the `session_runner` subworkflow.

All sessions use the **`session_runner`** subworkflow (`workflow/session_runner/`) which handles job scheduling, port allocation, SSH tunneling, and session registration with the platform.

## Deployments

The `session_runner` subworkflow has deployment-specific variants for different Activate platform installations:

| Deployment | File | Description |
|------------|------|-------------|
| `general` | `general.yaml` | Standard SLURM/PBS clusters |
| `emed` | `emed.yaml` | Einstein Medical clusters |
| `noaa` | `noaa.yaml` | NOAA clusters |
| `hsp` | `hsp.yaml` | HSP clusters |

Each session also has per-deployment workflow YAMLs (e.g., `general_v4.yaml`, `emed_v4.yaml`) that configure the UI form and scheduler settings for that deployment.

> **Note:** Some sessions also support Kubernetes deployments (e.g., `general_k8s_v4.yaml`), but the `session_runner` subworkflow is designed for compute (PBS/SLURM) clusters. Kubernetes sessions use a different orchestration approach with `kubectl` directly.

## Repository Structure

```
.
├── jupyterlab-host/         # JupyterLab scripts
│   ├── controller-v3.sh     #   Controller node setup
│   └── start-template-v3.sh #   Service start script
├── openvscode/              # VS Code scripts
├── vncserver/               # VNC desktop scripts
├── webshell/                # Web shell scripts
├── jupyter-host/            # Legacy Jupyter scripts
├── workflow/
│   ├── session_runner/      # Session runner subworkflow (per deployment)
│   ├── script_submitter/    # Script submitter subworkflow
│   ├── yamls/               # Workflow YAMLs (per session, per deployment)
│   ├── readmes/             # Per-session documentation shown in the UI
│   └── thumbnails/          # UI thumbnails
├── downloads/               # Binary dependencies (Git LFS)
└── examples/                # Example notebooks
```

## Developing a New Session

See [DeveloperGuide.md](DeveloperGuide.md) for step-by-step instructions on creating your own interactive session.
