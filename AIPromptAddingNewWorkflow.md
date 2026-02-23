# AI Assistant Context: Adding a New Session Workflow

This file provides detailed context and requirements for AI code assistants when creating new interactive session workflows. Reference this file along with DeveloperGuide.md when prompted to create a new workflow.

## Workflow Structure and Requirements

When creating a new interactive session workflow, the YAML will be named `[deployment]_v4.yaml` (e.g., `general_v4.yaml`, `emed_v4.yaml`)

## General Requirements

1. DO NOT add k8s support - create only the standard deployment workflow
2. Use the session_runner subworkflow (marketplace/session_runner/v1.3) for deployment
3. Follow the existing v4 session pattern with preprocessing + session_runner jobs
4. Ask the user which deployment target to use (general/emed/hsp/noaa) if not specified

## Files to Create

### 1. `[service-name]/controller-v3.sh`
   - Bash script that runs on the controller node (has internet access)
   - Install/download dependencies needed for the service
   - Make it idempotent (check if already installed before installing)
   - Use `service_parent_install_dir` variable (default: ${HOME}/pw/software)
   - Set appropriate executable permissions where needed

### 2. `[service-name]/start-template-v3.sh`
   - Bash script that starts the web service
   - MUST use `service_port` variable provided by session_runner
   - Create a `cancel.sh` script with commands to kill the service
   - Example structure:
     ```bash
     #!/bin/bash
     # Start service on service_port
     echo '#!/bin/bash' > cancel.sh
     chmod +x cancel.sh

     # Start your service
     /path/to/service --port=${service_port} &
     pid=$!
     echo "kill ${pid}" >> cancel.sh

     sleep inf
     ```

### 3. `workflow/yamls/[service-name]/[deployment]_v4.yaml`
   - Complete workflow YAML with:
     - `permissions: ['*']` section
     - `sessions.session` with `useTLS: false` and `redirect: true`
     - `preprocessing` job that:
       - Checks out this repo with sparse_checkout for your service directory
       - Creates `inputs.sh` with PW environment variables + form inputs
       - Uses `remoteHost: ${{ inputs.cluster.resource.ip }}`
     - `session_runner` job that:
       - Depends on preprocessing (`needs: [preprocessing]`)
       - Uses `marketplace/session_runner/v1.3`
       - Passes session, resource, cluster (slurm/pbs settings), and service configuration
       - Service config must include:
         - `start_service_script: ${PW_PARENT_JOB_DIR}/[service-name]/start-template-v3.sh`
         - `controller_script: ${PW_PARENT_JOB_DIR}/[service-name]/controller-v3.sh`
         - `inputs_sh: ${PW_PARENT_JOB_DIR}/inputs.sh`
         - `slug: ""` (or appropriate URL path like "lab", "vnc.html")
         - `rundir: ${PW_PARENT_JOB_DIR}`
     - Input form under `'on'.execute.inputs` with:
       - Standard `cluster` group (resource, scheduler, slurm, pbs settings)
       - Service-specific `service` group for your configuration options

### 4. `workflow/yamls/[service-name]/README.md`
   - User-facing documentation for the workflow. Structure:
     - **Title + one-line description** of what the service provides
     - **Features**: bullet list of key capabilities (runtime options, GPU support, scheduler support, etc.)
     - **Use Cases**: bullet list of typical scenarios users would launch this for
     - **Configuration**: subsection per major input group (e.g., OS, startup options, compute resources) — describe what each does and any valid values
     - **Requirements**: any software that must be present on the target node (e.g., module, binary, container runtime)
     - **Getting Started**: short numbered steps (select resource → configure → launch → access)
   - Keep it factual and concise — no implementation details, no internal paths

## Reference Implementations
- Look at `webshell/controller-v3.sh` and `webshell/start-template-v3.sh` for the simplest example
- Look at `workflow/yamls/jupyterlab-host/general_v4.yaml` for workflow structure (but don't copy JupyterLab-specific settings)
- Compare deployment variants like `general_v4.yaml` vs `emed_v4.yaml` to understand deployment-specific differences

## Key Constraints
- Service MUST listen on `service_port` (allocated by session_runner)
- Scripts MUST be idempotent (safe to run multiple times)
- DO NOT create k8s variants (no general_k8s_v4.yaml)
- Follow the exact directory structure: `[service-name]/` for scripts, `workflow/yamls/[service-name]/` for YAML
- Ensure all paths in the YAML use `${PW_PARENT_JOB_DIR}` prefix for scripts and inputs.sh
