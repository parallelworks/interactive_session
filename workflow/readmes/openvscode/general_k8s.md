# OpenVSCode Interactive Session
This workflow starts an OpenVSCode server [interactive session](https://github.com/parallelworks/interactive_session/blob/main/README-v3.md), on either a **Compute Cluster** (SLURM or PBS) or a **Kubernetes Cluster**.

Use the `Target Type` input to select your environment.

## Compute Cluster
Launches a Code Server server on a **Compute Cluster** using a user-specified release. 

## Kubernetes Cluster
This workflow launches Code Server on a **Kubernetes Cluster** using a user-specified image and resource settings. 

### Quick Start
- **Select a Kubernetes Cluster:** Choose your target K8s cluster.
- **Set Namespace:** Specify a namespace (e.g., default).
- **Choose an Image:** Default is `codercom/code-server:latest` from [this](https://hub.docker.com/r/codercom/code-server) DockerHub repository.
- **Configure Resources:** Set CPU, memory, and optional GPU requests/limits.
- **Run the Workflow:** Deploy Code Server and access it via a web interface.



