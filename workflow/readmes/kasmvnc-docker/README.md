# KasmVNC Container Desktop

A containerized remote desktop environment using Docker. Provides browser-based access to a full Linux desktop with GPU support. Container images are pulled directly from the registry, requiring no pre-download or local storage.

## Features

- **Multiple OS Options**: Rocky Linux 8/9 or Ubuntu 22.04
- **GPU Support**: Native GPU access for visualization and compute workloads
- **Custom Applications**: Launch any desktop application at startup
- **Flexible Storage**: Auto-mount common directories plus custom paths
- **Scheduler Support**: Works with both SLURM and PBS job schedulers
- **Docker-Based**: Uses standard Docker images from a container registry — no manual container setup needed

## Use Cases

- Running GUI applications (Firefox, MATLAB, RStudio, FSL, VMD, etc.)
- Scientific visualization and analysis
- Remote desktop access on cloud or Docker-enabled resources
- Development and testing in containerized environments

## Configuration

### Operating System
Choose from Rocky Linux 8, Rocky Linux 9, or Ubuntu 22.04 depending on your software requirements.

### Startup Application
Optionally specify a command to launch automatically (e.g., `firefox`, `rstudio`, `matlab`). Leave blank for a standard desktop.

### Additional Mount Paths
Common directories (`/p/home`, `/p/work`, `/scratch`, etc.) are automatically mounted if they exist. Specify additional paths (one per line) if needed.

### Compute Resources
Configure CPU, memory, and GPU requirements based on your workload. GPU support requires enabling the appropriate scheduler directives for your cluster.

## Requirements

- Docker must be installed and accessible on the target compute node (with or without `sudo`).

## Getting Started

1. Select your resource and scheduler settings
2. Choose your preferred OS and optional startup application
3. Launch the session
4. Access your desktop through the browser-based VNC interface

The session will run until cancelled or the walltime expires.
