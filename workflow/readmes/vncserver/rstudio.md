## RStudio Interactive Session
This workflow launches RStudio in a remote desktop [interactive session](https://github.com/parallelworks/interactive_session/blob/main/README-v3.md) accessible via a web browser on a **Compute Cluster** (SLURM or PBS) or as a container on a **Kubernetes Cluster** using the official RStudio docker [image](https://hub.docker.com/r/rocker/rstudio).

Use the `Target Type` input to select your environment.

## Compute Cluster
Runs RStudio in a remote desktop session on a SLURM or PBS cluster using TurboVNC, TigerVNC, or KasmVNC, depending on the installed VNC software.


## Kubernetes Cluster
Deploys an RStudio container on a Kubernetes cluster with user-defined image and resource settings.
- Note: No remote desktop is used; RStudio runs directly in the container.


### Quick Start
- **Select a Kubernetes Cluster:** Choose your target K8s cluster.
- **Set Namespace:** Specify a namespace (e.g., default).
- **Choose an Image:** Default is `rocker/rstudio` from [this](https://hub.docker.com/r/rocker/rstudio) DockerHub repository. 
- **Configure Resources:** Set CPU, memory, and optional GPU requests/limits.
- **Run the Workflow:** Deploy Code Server and access it via a web interface.

