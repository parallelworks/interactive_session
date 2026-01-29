# Session Runner Subworkflow

The `session_runner` is a marketplace subworkflow that simplifies starting a web service on a compute cluster and connecting it to the platform. It handles:

- Session management and URL routing
- Job scheduling (SLURM/PBS) or direct execution on the controller node
- Port allocation for the service
- SSH tunneling and connectivity to the platform

## Overview
The session runner takes scripts and configuration from the main workflow and orchestrates the execution of a web service. The main workflow defines the session in the YAML, prepares inputs, and passes the necessary scripts to the subworkflow.

## Basic Usage

```yaml
sessions:
  session:
    useTLS: false
    redirect: true

jobs:
  session_runner:
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
              is_disabled: false
              partition: ${{ inputs.cluster.slurm.partition }}
              scheduler_directives: ${{ inputs.cluster.slurm.scheduler_directives }}
              time: ${{ inputs.cluster.slurm.time }}
            pbs:
              is_disabled: true
              scheduler_directives: ""
          service:
            start_service_script: ${PW_PARENT_JOB_DIR}/my-service/start-template-v3.sh
            controller_script: ${PW_PARENT_JOB_DIR}/my-service/controller-v3.sh
            inputs_sh: ${PW_PARENT_JOB_DIR}/inputs.sh
            slug: my-slug
            rundir: ${PW_PARENT_JOB_DIR}
```

## Subworkflow Interface

### Required Inputs

| Parameter | Description |
|-----------|-------------|
| `session` | Reference to the session defined in the `sessions` section |
| `resource` | The compute cluster resource to run the service on |
| `cluster.scheduler` | Boolean - whether to submit to a job scheduler |
| `cluster.slurm` | SLURM scheduler configuration (partition, time, directives) |
| `cluster.pbs` | PBS scheduler configuration (directives) |
| `service.start_service_script` | Path to the script that starts the web service |
| `service.controller_script` | Path to the script that runs setup/installation on the controller |
| `service.inputs_sh` | Path to the shell script containing environment variables |
| `service.slug` | URL slug appended to the session URL (e.g., `lab`, `tree`, `vnc.html?...`) |
| `service.rundir` | Working directory for the service |

## Scripts Required by the Main Workflow

The main workflow must provide three key components:

### 1. Start Service Script (`start_service_script`)

This script runs on the **compute node** (or controller node if scheduler is disabled) and starts the actual web service.

**Key points:**
- The `service_port` variable is automatically defined by the subworkflow and **must be used** as the port the service listens on
- The script should use the inputs from `inputs.sh` which are sourced before execution
- Create a `cancel.sh` script to properly terminate the service when the job is canceled

**Example structure:**
```bash
#!/bin/bash
# service_port is already defined by the session_runner subworkflow

# Initialize cancel script
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh
echo "kill-my-server" >> cancel.sh

# Start your service on the provided port
start-my-server --port=${service_port}

# For long-running services, keep the script alive
sleep inf
```

**Available variables in the start service script:**
- `service_port` - The port allocated by the subworkflow (use this for your service)
- All variables exported in `inputs.sh`

### 2. Controller Script (`controller_script`)

This script runs on the **controller/login node** of the cluster, which typically has internet access. Use it for:

- Installing software and dependencies
- Downloading required files
- Any preparation that requires internet access

**Example structure:**
```bash
#!/bin/bash

# Install dependencies
if ! [ -f "${install_dir}/my-server" ]; then
    wget https://example.com/my-server.tar.gz
    tar -xzf my-server.tar.gz -C ${install_dir}
fi
```

All variables exported in `inputs.sh` are available in the controller script.


### 3. Inputs Script (`inputs_sh`)

This script exports environment variables used by both the controller and start service scripts. It is typically generated in a preprocessing job from the input form parameters.

**Example:**
```bash
export PATH=$HOME/pw:$PATH
export service_notebook_dir="${HOME}"
export service_password="mypassword"
export service_install_dir="${HOME}/pw/software"
```


## Execution Flow

1. **Preprocessing Job**: Prepares the scripts, creates `inputs.sh`, and optionally generates dynamic slugs
2. **Session Runner - Controller Phase**: Executes `controller_script` on the login/controller node for installation and setup
3. **Session Runner - Service Phase**: 
   - If `scheduler: true`: Submits job to SLURM/PBS, runs `start_service_script` on compute node
   - If `scheduler: false`: Runs `start_service_script` directly on the controller node
4. **Session Connection**: Platform establishes SSH tunnel and connects user to the service URL

## Best Practices

1. **Always use `service_port`**: The subworkflow allocates an available port
2. **Create a `cancel.sh` script**: Ensure proper cleanup when jobs are canceled
3. **Use the controller script for installations**: The controller node has internet access; compute nodes may not
4. **Export all variables in `inputs.sh`**: Prefix each line with `export`
5. **Handle missing variables gracefully**: Use defaults for optional parameters
6. **Sanitize `inputs.sh`**: Remove empty variables and undefined values