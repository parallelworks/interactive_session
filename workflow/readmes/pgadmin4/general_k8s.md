# pgAdmin 4 Interactive Session
This workflow starts a pgAdmin 4 server [interactive session](https://github.com/parallelworks/interactive_session/blob/main/README-v3.md), on either a **Compute Cluster** (SLURM or PBS) or a **Kubernetes Cluster**.

Use the `Target Type` input to select your environment.

## Compute Cluster
Launches a pgAdmin 4 server on a **Compute Cluster** using a user-specified docker image. Default is `dpage/pgadmin4` from [this](https://hub.docker.com/r/dpage/pgadmin4/) DockerHub repository.

## Kubernetes Cluster
This workflow launches pgAdmin 4 on a **Kubernetes Cluster** using a user-specified image and resource settings. 

### Quick Start
- **Select a Kubernetes Cluster:** Choose your target K8s cluster.
- **Set Namespace:** Specify a namespace (e.g., default).
- **Choose an Image:** Default is `dpage/pgadmin4` from [this](https://hub.docker.com/r/dpage/pgadmin4/) DockerHub repository.
- **Configure Resources:** Set CPU, memory, and optional GPU requests/limits.
- **Run the Workflow:** Deploy pgAdmin 4 and access it via a web interface.



