# Developer Guide: Creating a New Interactive Session

A session requires three files:

| File | Runs on | Purpose |
|------|---------|---------|
| `controller-v3.sh` | Controller (login) node | Install software, download dependencies |
| `start-template-v3.sh` | Controller or compute node | Start the web service |
| Workflow YAML | Platform | Define the UI form, generate `inputs.sh`, call `session_runner` |

The controller node always has internet access. The compute node may not.

## 1. Create the Controller Script

File: `my-session/controller-v3.sh`

This script runs **before** the service starts. Use it to install dependencies that require internet access. All variables from `inputs.sh` are available.

```bash
#!/usr/bin/env bash
set -o pipefail

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

# Install your software if not already present
if ! [ -f "${service_parent_install_dir}/my-server" ]; then
    echo "Installing my-server..."
    mkdir -p ${service_parent_install_dir}
    wget https://example.com/my-server.tar.gz -O /tmp/my-server.tar.gz
    tar -xzf /tmp/my-server.tar.gz -C ${service_parent_install_dir}
fi
```

Keep it idempotent -- check if software exists before installing.

## 2. Create the Start Service Script

File: `my-session/start-template-v3.sh`

This script starts the web service. The `session_runner` subworkflow provides the `service_port` variable -- your service **must** listen on this port. All variables from `inputs.sh` are available.

```bash
#!/bin/bash
# service_port is provided by the session_runner subworkflow

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

# Create a cancel.sh script so the platform can stop the service
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh

# Start your service
${service_parent_install_dir}/my-server --port=${service_port} &
pid=$!
echo "kill ${pid}" >> cancel.sh

sleep inf
```

Key requirements:
- **Use `service_port`** as the listening port. It is allocated automatically.
- **Write a `cancel.sh`** script that kills your service process. The platform runs this on cleanup.
- **End with `sleep inf`** to keep the job alive (or run the service in the foreground).

## 3. Create the Workflow YAML

File: `workflow/yamls/my-session/general_v4.yaml`

The YAML has three responsibilities:
1. Define the user input form (under `on.execute.inputs`)
2. Generate `inputs.sh` from the form values (in the `preprocessing` job)
3. Call the `session_runner` subworkflow with the paths to your scripts

### Minimal Example

```yaml
permissions:
  - '*'

sessions:
  session:
    useTLS: false
    redirect: true

jobs:
  preprocessing:
    ssh:
      remoteHost: ${{ inputs.cluster.resource.ip }}
    steps:
      - name: Checkout
        uses: parallelworks/checkout
        with:
          repo: https://github.com/parallelworks/interactive_session.git
          branch: main
          sparse_checkout:
            - my-session
      - name: Create Inputs
        run: |
          set -x
          # Capture PW environment variables
          env | grep '^PW_' | grep -v 'PW_API_KEY' > inputs.sh
          sed -i 's/=\(.*\)/="\1"/' inputs.sh

          # Add your form inputs
          cat <<'EOF' >> inputs.sh
          basepath=/me/session/${PW_USER}/${{ sessions.session }}
          PATH=$HOME/pw:$PATH
          service_parent_install_dir="${{ inputs.service.parent_install_dir }}"
          EOF

          # Clean up and export
          sed -i '/=\s*$\|=undefined\s*$/d' inputs.sh
          sed -i '/=""/d' inputs.sh
          sed -i 's/^/export /' inputs.sh

  session_runner:
    needs:
      - preprocessing
    ssh:
      remoteHost: ${{ inputs.cluster.resource.ip }}
    steps:
      - uses: marketplace/session_runner/v1.3
        early-cancel: any-job-failed
        with:
          session: ${{ sessions.session }}
          resource: ${{ inputs.cluster.resource }}
          cluster:
            scheduler: ${{ inputs.cluster.scheduler }}
            slurm:
              is_disabled: ${{ inputs.cluster.resource.provider == 'existing' && inputs.cluster.resource.schedulerType != 'slurm' || inputs.cluster.scheduler == false }}
              partition: ${{ inputs.cluster.slurm.partition }}
              scheduler_directives: ${{ inputs.cluster.slurm.scheduler_directives }}
              time: ${{ inputs.cluster.slurm.time }}
            pbs:
              is_disabled: ${{ inputs.cluster.resource.schedulerType != 'pbs' || inputs.cluster.scheduler == false }}
              scheduler_directives: ${{ inputs.cluster.pbs.scheduler_directives }}
          service:
            start_service_script: ${PW_PARENT_JOB_DIR}/my-session/start-template-v3.sh
            controller_script: ${PW_PARENT_JOB_DIR}/my-session/controller-v3.sh
            inputs_sh: ${PW_PARENT_JOB_DIR}/inputs.sh
            slug: ""
            rundir: ${PW_PARENT_JOB_DIR}

'on':
  execute:
    inputs:
      cluster:
        type: group
        label: Compute Cluster Settings
        items:
          resource:
            type: compute-clusters
            label: Service host
            include-workspace: false
          scheduler:
            type: boolean
            default: false
            label: Schedule Job?
            hidden: ${{ inputs.cluster.resource.schedulerType == '' }}
            ignore: ${{ .hidden }}
          slurm:
            type: group
            label: SLURM Directives
            hidden: ${{ inputs.cluster.resource.provider == 'existing' && inputs.cluster.resource.schedulerType != 'slurm' || inputs.cluster.scheduler == false }}
            items:
              is_disabled:
                type: boolean
                hidden: true
                default: ${{ inputs.cluster.resource.provider == 'existing' && inputs.cluster.resource.schedulerType != 'slurm' || inputs.cluster.scheduler == false }}
              partition:
                type: slurm-partitions
                label: SLURM partition
                optional: true
                resource: ${{ inputs.cluster.resource }}
              time:
                label: Walltime
                type: string
                default: '01:00:00'
              scheduler_directives:
                type: editor
                optional: true
          pbs:
            type: group
            label: PBS Directives
            hidden: ${{ inputs.cluster.resource.schedulerType != 'pbs' || inputs.cluster.scheduler == false }}
            items:
              is_disabled:
                type: boolean
                hidden: true
                default: ${{ inputs.cluster.resource.schedulerType != 'pbs' || inputs.cluster.scheduler == false }}
              scheduler_directives:
                type: editor
      service:
        type: group
        label: My Session Settings
        items:
          parent_install_dir:
            label: Install Directory
            type: string
            default: ${HOME}/pw/software
```

### Understanding the `session_runner` Interface

The `session_runner` subworkflow accepts these inputs:

| Parameter | Description |
|-----------|-------------|
| `session` | Reference to the session object defined in `sessions:` |
| `resource` | The compute cluster resource |
| `cluster.scheduler` | `true` to submit to SLURM/PBS, `false` to run on controller |
| `cluster.slurm` | SLURM settings: `is_disabled`, `partition`, `time`, `scheduler_directives` |
| `cluster.pbs` | PBS settings: `is_disabled`, `scheduler_directives` |
| `service.start_service_script` | Path to your start script |
| `service.controller_script` | Path to your controller script |
| `service.inputs_sh` | Path to the generated `inputs.sh` |
| `service.slug` | URL path appended to the session URL (e.g., `lab`, `vnc.html`) |
| `service.rundir` | Working directory for the service |

### What the `session_runner` Does

1. **Preprocessing** -- Combines `inputs.sh` + `controller-v3.sh` and runs it on the controller node. Then combines `inputs.sh` + `start-template-v3.sh` into the final start script, injecting port allocation and cleanup traps.
2. **Job submission** -- If `scheduler: true`, submits the start script via `sbatch`/`qsub` to a compute node. If `false`, runs it directly on the controller node.
3. **Wait for start** -- Polls for the `job.started` marker file.
4. **Create session** -- Waits for the service to respond on its port, then registers the session URL with the platform.
5. **Cleanup** -- On workflow cancellation, runs `cancel.sh` to stop the service.

### Variables Available in Your Scripts

The `session_runner` injects these into the start script before your code runs:

| Variable | Description |
|----------|-------------|
| `service_port` | The allocated port. Your service **must** listen on this port. |
| `resource_jobdir` | The parent job directory (`$PW_PARENT_JOB_DIR`) |

All variables exported in `inputs.sh` are also available in both scripts.

## 4. Deployment-Specific Variants

To support multiple deployments, create a separate YAML per platform deployment:

```
workflow/yamls/my-session/
├── general_v4.yaml      # Standard SLURM/PBS clusters
├── emed_v4.yaml         # EMED clusters
├── noaa_v4.yaml         # NOAA clusters
└── hsp_v4.yaml          # HSP clusters
```

Each YAML uses the corresponding `session_runner` variant (e.g., `marketplace/session_runner/v1.3` resolves to the appropriate deployment). The differences are typically in scheduler directives, partition names, and cluster-specific environment setup in the `inputs.sh` generation.

## Existing Sessions as Reference

Look at these for working examples:

- **Simplest**: `webshell/` -- Starts a single `ttyd` process, minimal controller setup.
- **Typical**: `jupyterlab-host/` -- Conda installation in controller, nginx proxy + JupyterLab in start script.
- **Complex**: `vncserver/` -- Multiple desktop environment options, Singularity/Docker containers.
