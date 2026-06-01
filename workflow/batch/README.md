# Batch Workflows

Activate platform workflows that submit batch (non-interactive) compute jobs on HPC clusters. These workflows use `workflow/script_submitter` as a subworkflow for job submission and scheduler integration, but do not follow the interactive session framework (no persistent service, no browser-based UI, no session tunneling).

## Structure

Each subdirectory contains one or more `hsp.yaml` workflow files targeting HSP-managed clusters. Workflows support both SLURM and PBS schedulers.

## Available Workflows

| Directory | Application |
|-----------|-------------|
| `helios/` | Helios rotary-wing CFD solver (CREATE-AV) |
| `kestrel/` | Kestrel fixed-wing CFD solver (CREATE-AV) |
