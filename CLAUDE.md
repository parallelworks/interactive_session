# CLAUDE.md — Interactive Sessions Repository

## Project Overview

This repository contains the **Interactive Sessions** framework for the [Activate platform](https://parallelworks.com). It enables browser-based interactive computing sessions (JupyterLab, VS Code, VNC desktops, web terminals) on remote compute clusters.

Each session type consists of:
- A **controller script** (`controller-v3.sh`) — runs on the login node, handles installation/setup with internet access
- A **start script** (`start-template-v3.sh`) — runs on the compute node, launches the service
- **Workflow YAML files** (`workflow/yamls/[service-name]/`) — define the UI form and orchestrate execution via the Activate platform

## Repository Structure

```
[service-name]/
├── controller-v3.sh          # Setup/installation (runs on login node)
└── start-template-v3.sh      # Service startup (runs on compute/login node)

workflow/
├── yamls/[service-name]/     # Per-deployment workflow YAML files
│   ├── general_v4.yaml       # Standard SLURM/PBS clusters
│   ├── emed_v4.yaml
│   ├── hsp_v4.yaml
│   └── noaa_v4.yaml
├── readmes/[service-name]/   # User-facing documentation
├── thumbnails/               # UI thumbnails for the Activate platform
├── session_runner/           # Subworkflow for job orchestration
│   ├── general.yaml
│   ├── emed.yaml
│   ├── hsp.yaml
│   └── noaa.yaml
└── k8s/                      # Kubernetes-specific configs (separate)

downloads/                    # Binary dependencies (Git LFS)
examples/                     # Example configurations
```

**Available services**: `jupyterlab-host`, `jupyter-host`, `webshell`, `openvscode`, `vncserver`, `kasmvnc-docker`, `kasmvnc-singularity`, `open-notebook`

**Deployment variants**: `general`, `emed`, `hsp`, `noaa` (+ kubernetes for some)

## No Build System

There is **no build system, test suite, or linter**. This is a configuration/workflow repository. Deployment happens by the Activate platform cloning this repo and executing scripts directly. Validation is manual, on target clusters.

## Adding a New Session — Required Steps

See `AIPromptAddingNewWorkflow.md` and `DevelopersGuide.md` for full details. Summary:

1. Create `[service-name]/controller-v3.sh` (login node, has internet)
2. Create `[service-name]/start-template-v3.sh` (compute node, may not have internet)
3. Create `workflow/yamls/[service-name]/general_v4.yaml` (and emed, hsp, noaa variants)
4. Create `workflow/readmes/[service-name]/README.md`
5. Add thumbnails to `workflow/thumbnails/`

Use these as reference implementations:
- **Simplest**: `webshell/` (minimal, just ttyd terminal)
- **Typical**: `jupyterlab-host/` (conda, nginx proxy, JupyterLab)
- **Complex**: `vncserver/` (containers, multiple desktop environments)

## Workflow YAML Structure

Each workflow YAML has three jobs:
1. **permissions** — defines which users can run the workflow
2. **preprocessing** — generates `inputs.sh` from form inputs + platform environment variables
3. **session_runner** — the `marketplace/session_runner` subworkflow that orchestrates job submission and SSH tunneling

Always use `marketplace/session_runner` (current version: `v1.3` or `v1.4`). Do NOT implement job submission logic directly.

## Critical Rules and Conventions

### Scripts
- Scripts MUST be **idempotent** — safe to re-run without side effects (check before installing)
- Service MUST listen on `${service_port}` — this port is dynamically allocated by `session_runner`
- Scripts MUST create `cancel.sh` for graceful shutdown
- The start script (compute node) MUST end with `sleep inf` (or equivalent) to keep the job alive
- All variables arrive via sourced `inputs.sh` (do not hardcode paths or values)
- Use `${PW_PARENT_JOB_DIR}` for all job directory references
- Use `service_parent_install_dir` for software install path (default: `${HOME}/pw/software`)

### Workflow YAMLs
- All paths in YAML MUST use `${PW_PARENT_JOB_DIR}` prefix
- DO NOT add Kubernetes support in standard SLURM/PBS workflows — create those 
- Form inputs are organized into groups: `cluster` (resource selection, scheduler) and `service` (service-specific options)
- Form values are accessible as `inputs.service.*` and `inputs.cluster.*` in YAML

### Scheduler
- `scheduler: true` → job submitted via sbatch/qsub to a compute node
- `scheduler: false` → job runs on the login/controller node
- Support both SLURM and PBS

## Git and Deployment

- Push directly to `main` branch (`git@github.com:parallelworks/interactive_session.git`)
- No PRs or branches documented in the developer guide
- Git LFS is configured for large binaries in `downloads/` (juice binary, VNC containers)
- Do not store large binaries outside `downloads/` without Git LFS


