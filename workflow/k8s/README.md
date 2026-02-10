# Kubernetes Workflows

This directory contains **standalone Kubernetes workflows** for the Activate platform. These workflows are completely self-contained and designed to run exclusively on Kubernetes clusters.

## Overview

Each workflow in this directory is a single YAML file that:
- **Requires no other files to run** - All configuration is self-contained
- **Only supports Kubernetes** - These workflows deploy directly to Kubernetes clusters using `kubectl`
- **Creates Kubernetes resources** - Handles Deployments, Services, and PersistentVolumeClaims
- **Manages the full lifecycle** - From deployment creation to cleanup


## Hybrid Workflows (`workflow/yamls/`)
- **Location**: `workflow/yamls/<service>/<deployment>_k8s_v4.yaml`
- **Target**: Can run on **either** compute clusters (PBS/SLURM) **or** Kubernetes clusters
- **Architecture**:
  - For compute clusters: Uses `session_runner` subworkflow with bash scripts (`controller-v3.sh`, `start-template-v3.sh`)
  - For Kubernetes: Conditionally executes Kubernetes jobs similar to standalone workflows
- **Flexible**: One workflow file supports multiple deployment targets

### Example Comparison

For JupyterLab:
- **Standalone K8s**: [workflow/k8s/jupyter/general.yaml](jupyter/general.yaml) - Pure Kubernetes deployment
- **Hybrid**: [workflow/yamls/jupyterlab-host/general_k8s_v4.yaml](../yamls/jupyterlab-host/general_k8s_v4.yaml) - Can run on compute clusters OR Kubernetes


### When to Use Each Approach

#### Use Standalone K8s Workflows (`workflow/k8s/`) when:
- You only need Kubernetes support
- You want simpler, more focused workflows
- You're deploying containerized services without custom setup scripts
- You don't need the `session_runner` subworkflow features

#### Use Hybrid Workflows (`workflow/yamls/`) when:
- You need to support both compute clusters AND Kubernetes
- You have existing bash installation scripts (controller-v3.sh, start-template-v3.sh)
- You want a single workflow that adapts to the selected resource type
- You need the `session_runner` features for compute clusters