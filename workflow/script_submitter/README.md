# Script Submitter

A flexible workflow for running user-defined scripts on cloud and on-prem compute resources using SSH, PBS, or SLURM. Can be used as a **standalone workflow** (with its own UI) or as a **subworkflow** called from other workflows.

## How It Works

The user supplies a script and (when applicable) configures scheduler directives. The workflow automatically generates a fully populated job script—including the shebang, run directory, scheduler options, and user script—and executes or submits it on the target system.

The workflow auto-detects whether the selected resource is a SLURM or PBS cluster. Based on this, users can choose to:

1. **Use the scheduler agent** (recommended): Provision a compute node dynamically via `parallelworks/scheduler-agent`. The agent handles node allocation, waits for the node to become ready, and then executes the script over SSH through a jump node. This is the recommended option for single-node jobs as it simplifies job management and cleanup. Note: the scheduler agent does not support multi-node jobs.

2. **Schedule the job directly**: Submit to the cluster's scheduler (SLURM via `sbatch` or PBS via `qsub`). The workflow monitors the job until completion. Use this option when you need multi-node support (e.g., distributed MPI jobs).

3. **Run directly on the controller**: Execute the script immediately on the login/controller node via SSH.

## Monitoring & Cleanup

For PBS and SLURM direct submissions, the workflow continuously monitors job status until completion or until the job is no longer found in the queue. If the workflow is canceled, the cleanup logic automatically terminates the remote job (`qdel` or `scancel`) to prevent orphaned workloads.

When using the scheduler agent, cleanup is handled by the agent itself.

## Usage as a Standalone Workflow

Run the script submitter directly from the UI:
- Select a compute resource
- Type your script or provide a path to an existing script
- Configure scheduler options if needed
- The default script demonstrates how workflow inputs (e.g., `${{ inputs.rundir }}`) can be referenced directly

## Usage as a Subworkflow

Call the script submitter from another workflow to submit scripts programmatically:


### Example: Scheduler Agent (Recommended)

Use the scheduler agent for single-node jobs:

```yaml
jobs:
  run_my_script:
    ssh:
      remoteHost: ${{ inputs.cluster.resource.ip }}
    steps:
      - uses: marketplace/script_submitter/v3.5
        with:
          resource: ${{ inputs.cluster.resource }}
          rundir: ${PW_JOB_DIR}
          script: |
            echo "Running on $(hostname) at $(date)"
            python my_analysis.py --input data.csv
          scheduler: ${{ inputs.cluster.scheduler }}
          use_scheduler_agent: true
          slurm:
            is_disabled: ${{ inputs.cluster.slurm.is_disabled }}
            partition: ${{ inputs.cluster.slurm.partition }}
            time: ${{ inputs.cluster.slurm.time }}
            scheduler_directives: ${{ inputs.cluster.slurm.scheduler_directives }}
          pbs:
            is_disabled: ${{ inputs.cluster.pbs.is_disabled }}
            scheduler_directives: ${{ inputs.cluster.pbs.scheduler_directives }}
```

### Example: Inline Script

Write your script directly in the workflow YAML:

```yaml
jobs:
  run_my_script:
    ssh:
      remoteHost: ${{ inputs.cluster.resource.ip }}
    steps:
      - uses: marketplace/script_submitter/v3.5
        with:
          resource: ${{ inputs.cluster.resource }}
          rundir: ${PW_JOB_DIR}
          script: |
            echo "Running on $(hostname) at $(date)"
            echo "Working directory: $(pwd)"
            
            # Add your commands here
            python my_analysis.py --input data.csv
          scheduler: ${{ inputs.cluster.scheduler }}
          slurm:
            is_disabled: ${{ inputs.cluster.slurm.is_disabled }}
            partition: ${{ inputs.cluster.slurm.partition }}
            time: ${{ inputs.cluster.slurm.time }}
            scheduler_directives: ${{ inputs.cluster.slurm.scheduler_directives }}
          pbs:
            is_disabled: ${{ inputs.cluster.pbs.is_disabled }}
            scheduler_directives: ${{ inputs.cluster.pbs.scheduler_directives }}
```

### Example: Existing Script File

Reference a script that was created in a previous job step:

```yaml
jobs:
  prepare:
    ssh:
      remoteHost: ${{ inputs.cluster.resource.ip }}
    steps:
      - name: Create script
        run: |
          cat <<'EOF' > ${PW_JOB_DIR}/my-script.sh
          echo "Running simulation..."
          ./run_simulation --config config.yaml
          EOF

  submit:
    needs: [prepare]
    ssh:
      remoteHost: ${{ inputs.cluster.resource.ip }}
    steps:
      - uses: marketplace/script_submitter/v3.5
        with:
          resource: ${{ inputs.cluster.resource }}
          rundir: ${PW_JOB_DIR}
          use_existing_script: true
          script_path: ${PW_JOB_DIR}/my-script.sh
          scheduler: ${{ inputs.cluster.scheduler }}
          slurm:
            is_disabled: ${{ inputs.cluster.slurm.is_disabled }}
            partition: ${{ inputs.cluster.slurm.partition }}
            time: ${{ inputs.cluster.slurm.time }}
          pbs:
            is_disabled: ${{ inputs.cluster.pbs.is_disabled }}
            scheduler_directives: ${{ inputs.cluster.pbs.scheduler_directives }}
```


## Inputs

| Input | Description | Required |
|-------|-------------|----------|
| `resource` | The compute cluster resource | Yes |
| `rundir` | Working directory for script execution | Yes |
| `script` | Script content (when `use_existing_script: false`) | No |
| `use_existing_script` | Use a script file instead of inline content | No |
| `script_path` | Path to existing script (when `use_existing_script: true`) | No |
| `shebang` | Script shebang (default: `#!/bin/bash`) | No |
| `scheduler` | Submit to job scheduler (true/false) | No |
| `use_scheduler_agent` | Use the scheduler agent instead of direct submission (true/false, default: false) | No |
| `slurm` | SLURM scheduler options | No |
| `pbs` | PBS scheduler options | No |

## Outputs

The script output is written to `run.${PW_JOB_ID}.out` in the run directory.

## Building Custom Workflows

The script submitter can serve as a template for more specialized workflows. The script body may be replaced or hidden, and additional UI inputs may be added to tailor the workflow to specific use cases or resource requirements.
