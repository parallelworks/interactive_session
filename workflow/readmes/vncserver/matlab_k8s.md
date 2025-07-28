## MATLAB Interactive Session
This workflow launches MATLAB in a remote desktop [interactive session](https://github.com/parallelworks/interactive_session/blob/main/README-v3.md) accessible via a web browser on a **Compute Cluster** (SLURM or PBS) or as a container on a **Kubernetes Cluster** using the official MATLAB docker [image](https://hub.docker.com/r/mathworks/matlab).

Use the `Target Type` input to select your environment.

## Compute Cluster
Runs MATLAB in a remote desktop session on a SLURM or PBS cluster using TurboVNC, TigerVNC, or KasmVNC, depending on the installed VNC software.

### Requirements:
- MATLAB must be installed on the target resource.
- **Users must have access to a valid MATLAB license.**
- Users must provide a command to load and start MATLAB (e.g., matlab -desktop).

## Kubernetes Cluster
Deploys a MATLAB container on a Kubernetes cluster with user-defined image and resource settings.
- Note: No remote desktop is used; MATLAB runs directly in the container.
- Requirement: **Users must provide their own MATLAB account or license.**


### Quick Start
- **Select a Kubernetes Cluster:** Choose your target K8s cluster.
- **Set Namespace:** Specify a namespace (e.g., default).
- **Choose an Image:** Default is `mathworks/matlab:r2025a` from [this](https://hub.docker.com/r/mathworks/matlab) DockerHub repository. 
- **Configure Resources:** Set CPU, memory, and optional GPU requests/limits.
- **Run the Workflow:** Deploy Code Server and access it via a web interface.

