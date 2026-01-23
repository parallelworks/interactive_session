# Script Submitter
This workflow provides a flexible way to run user-defined scripts cloud compute and on-prem resources using SSH, PBS, or SLURM. The user supplies a script and (when applicable) configures scheduler directives directly through the workflow UI. Based on these selections, the workflow automatically generates a fully populated job script—including the shebang, run directory, scheduler options, and user script—and executes or submits it on the target system.

## How it works
- **SSH execution:** The workflow creates a simple script and executes it directly on the remote host via SSH.
- **PBS execution:** The workflow constructs a PBS-compatible job script using the user-provided account and scheduler directives, submits it with qsub, monitors the queue, and waits for completion.
- **SLURM execution:** The workflow builds a SLURM job script using user-selected options, and any additional scheduler directives. The script is submitted with sbatch, and its status is monitored using squeue and sacct.

## Monitoring & Cleanup
For PBS and SLURM, the workflow continuously monitors job status until completion or until the job is no longer found in the queue.

If the workflow run itself is canceled, the cleanup logic automatically attempts to terminate the remote job (qdel or scancel) to prevent orphaned workloads on the compute resource.

## Usage Notes
- The default script demonstrates how workflow inputs (e.g., ${{ inputs.rundir }}) can be referenced directly inside the executed script.
- This workflow can also serve as a template for more specialized workflows. The script body may be replaced or hidden, and additional UI inputs may be added to tailor the workflow to specific use cases or resource requirements.
- This makes the workflow a convenient foundation for building custom compute workflows.